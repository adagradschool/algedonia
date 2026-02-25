package adapter

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type codexAppSession struct {
	cmd       *exec.Cmd
	stdin     io.WriteCloser
	stdout    io.ReadCloser
	stderr    io.ReadCloser
	collector *outputCollector

	streamR *io.PipeReader
	streamW *io.PipeWriter

	sessionID string
	threadID  string
	turnID    string

	reqID   atomic.Int64
	mu      sync.Mutex
	pending map[string]chan map[string]interface{}
	steer   strings.Builder

	resultCh chan *ExitResult
	errCh    chan error
	doneCh   chan struct{}
}

func startCodexAppServer(workdir, task, sessionID string, collector *outputCollector) (*codexAppSession, error) {
	cmd := exec.Command("codex", "app-server", "--listen", "stdio://")
	cmd.Dir = workdir
	cmd.Env = os.Environ()

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("codex app-server stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("codex app-server stdout: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("codex app-server stderr: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start codex app-server: %w", err)
	}

	r, w := io.Pipe()
	s := &codexAppSession{
		cmd:       cmd,
		stdin:     stdin,
		stdout:    stdout,
		stderr:    stderr,
		collector: collector,
		streamR:   r,
		streamW:   w,
		sessionID: sessionID,
		pending:   make(map[string]chan map[string]interface{}),
		resultCh:  make(chan *ExitResult, 1),
		errCh:     make(chan error, 1),
		doneCh:    make(chan struct{}),
	}

	go s.readStdoutLoop()
	go s.readStderrLoop()
	go s.waitCmdLoop()

	if err := s.initializeAndStartTurn(workdir, task); err != nil {
		_ = s.Kill(2 * time.Second)
		return nil, err
	}

	return s, nil
}

func (s *codexAppSession) Attach() (io.Reader, io.WriteCloser, error) {
	return s.streamR, &codexSteerWriter{session: s}, nil
}

func (s *codexAppSession) Wait() (*ExitResult, error) {
	select {
	case res := <-s.resultCh:
		return res, nil
	case err := <-s.errCh:
		return nil, err
	}
}

func (s *codexAppSession) Kill(grace time.Duration) error {
	// Best effort: interrupt active turn first.
	s.mu.Lock()
	threadID, turnID := s.threadID, s.turnID
	s.mu.Unlock()
	if threadID != "" && turnID != "" {
		_, _ = s.request("turn/interrupt", map[string]interface{}{
			"threadId": threadID,
			"turnId":   turnID,
		}, 2*time.Second)
	}

	if s.cmd.Process == nil {
		return nil
	}

	_ = s.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-s.doneCh:
		return nil
	case <-time.After(grace):
		_ = s.cmd.Process.Kill()
		<-s.doneCh
		return nil
	}
}

func (s *codexAppSession) Steer(data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for _, b := range data {
		switch b {
		case 3: // Ctrl-C
			threadID, turnID := s.threadID, s.turnID
			if threadID != "" && turnID != "" {
				go s.request("turn/interrupt", map[string]interface{}{
					"threadId": threadID,
					"turnId":   turnID,
				}, 3*time.Second)
				s.appendStream("\n[codex-app-server] turn interrupt requested\n")
			}
		case '\r', '\n':
			line := strings.TrimSpace(s.steer.String())
			s.steer.Reset()
			if line != "" && s.threadID != "" && s.turnID != "" {
				go func(threadID, turnID, line string) {
					_, err := s.request("turn/steer", map[string]interface{}{
						"threadId":       threadID,
						"expectedTurnId": turnID,
						"input": []map[string]interface{}{
							{
								"type":          "text",
								"text":          line,
								"text_elements": []interface{}{},
							},
						},
					}, 15*time.Second)
					if err != nil {
						s.appendStream(fmt.Sprintf("[codex-app-server] steer failed: %v\n", err))
					}
				}(s.threadID, s.turnID, line)
				s.appendStream(fmt.Sprintf("\n[you → codex] %s\n", line))
			}
		default:
			s.steer.WriteByte(b)
		}
	}
	return nil
}

func (s *codexAppSession) initializeAndStartTurn(workdir, task string) error {
	_, err := s.request("initialize", map[string]interface{}{
		"clientInfo": map[string]interface{}{
			"name":    "algedonia-daemon",
			"title":   "Algedonia Daemon",
			"version": "0.1.0",
		},
		"capabilities": map[string]interface{}{
			"experimentalApi": false,
		},
	}, 15*time.Second)
	if err != nil {
		return fmt.Errorf("initialize failed: %w", err)
	}

	if err := s.notify("initialized", map[string]interface{}{}); err != nil {
		return fmt.Errorf("initialized notify failed: %w", err)
	}

	threadResp, err := s.request("thread/start", map[string]interface{}{
		"cwd":                    workdir,
		"approvalPolicy":         "never",
		"sandbox":                "danger-full-access",
		"experimentalRawEvents":  false,
		"persistExtendedHistory": false,
	}, 20*time.Second)
	if err != nil {
		return fmt.Errorf("thread/start failed: %w", err)
	}

	threadID := nestedString(threadResp, "thread", "id")
	if threadID == "" {
		return fmt.Errorf("thread/start response missing thread.id")
	}

	s.mu.Lock()
	s.threadID = threadID
	s.mu.Unlock()

	turnResp, err := s.request("turn/start", map[string]interface{}{
		"threadId":       threadID,
		"approvalPolicy": "never",
		"sandboxPolicy": map[string]interface{}{
			"type": "dangerFullAccess",
		},
		"input": []map[string]interface{}{
			{
				"type":          "text",
				"text":          task,
				"text_elements": []interface{}{},
			},
		},
	}, 20*time.Second)
	if err != nil {
		return fmt.Errorf("turn/start failed: %w", err)
	}

	turnID := nestedString(turnResp, "turn", "id")
	if turnID == "" {
		return fmt.Errorf("turn/start response missing turn.id")
	}

	s.mu.Lock()
	s.turnID = turnID
	s.mu.Unlock()

	return nil
}

func (s *codexAppSession) readStdoutLoop() {
	dec := json.NewDecoder(s.stdout)
	for {
		var msg map[string]interface{}
		if err := dec.Decode(&msg); err != nil {
			if err != io.EOF {
				select {
				case s.errCh <- fmt.Errorf("codex app-server decode: %w", err):
				default:
				}
			}
			return
		}
		s.handleMessage(msg)
	}
}

func (s *codexAppSession) readStderrLoop() {
	scanner := bufio.NewScanner(s.stderr)
	for scanner.Scan() {
		s.appendStream("[codex] " + scanner.Text() + "\n")
	}
}

func (s *codexAppSession) waitCmdLoop() {
	_ = s.cmd.Wait()
	close(s.doneCh)
}

func (s *codexAppSession) handleMessage(msg map[string]interface{}) {
	if id, ok := msg["id"]; ok && msg["method"] == nil {
		key := fmt.Sprintf("%v", id)
		s.mu.Lock()
		ch := s.pending[key]
		delete(s.pending, key)
		s.mu.Unlock()
		if ch != nil {
			ch <- msg
		}
		return
	}

	method, _ := msg["method"].(string)
	params, _ := msg["params"].(map[string]interface{})

	if id, ok := msg["id"]; ok {
		// Server request -> respond with empty result to avoid deadlocks.
		_ = s.respond(id, map[string]interface{}{})
	}

	switch method {
	case "item/agentMessage/delta", "item/commandExecution/outputDelta", "item/reasoning/textDelta":
		if delta, ok := params["delta"].(string); ok {
			s.appendStream(delta)
		}
	case "turn/started":
		if turn, ok := params["turn"].(map[string]interface{}); ok {
			if turnID, _ := turn["id"].(string); turnID != "" {
				s.mu.Lock()
				s.turnID = turnID
				s.mu.Unlock()
			}
		}
	case "turn/completed":
		exitCode := 1
		if turn, ok := params["turn"].(map[string]interface{}); ok {
			if status, _ := turn["status"].(string); status == "completed" {
				exitCode = 0
			}
		}
		s.resultCh <- &ExitResult{
			ExitCode:  exitCode,
			SessionID: s.sessionID,
			Output:    s.collector.Bytes(),
		}
	case "error":
		s.errCh <- fmt.Errorf("codex app-server error notification: %v", params)
	}
}

func (s *codexAppSession) appendStream(text string) {
	if text == "" {
		return
	}
	_, _ = s.collector.Write([]byte(text))
	go func(payload string) {
		_, _ = s.streamW.Write([]byte(payload))
	}(text)
}

func (s *codexAppSession) request(method string, params map[string]interface{}, timeout time.Duration) (map[string]interface{}, error) {
	id := fmt.Sprintf("%d", s.reqID.Add(1))
	respCh := make(chan map[string]interface{}, 1)

	s.mu.Lock()
	s.pending[id] = respCh
	s.mu.Unlock()

	if err := s.send(map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  method,
		"params":  params,
	}); err != nil {
		return nil, err
	}

	select {
	case resp := <-respCh:
		if errVal, ok := resp["error"]; ok && errVal != nil {
			return nil, fmt.Errorf("%s failed: %v", method, errVal)
		}
		result, _ := resp["result"].(map[string]interface{})
		return result, nil
	case <-time.After(timeout):
		return nil, fmt.Errorf("%s timeout", method)
	}
}

func (s *codexAppSession) notify(method string, params map[string]interface{}) error {
	return s.send(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
	})
}

func (s *codexAppSession) respond(id interface{}, result map[string]interface{}) error {
	return s.send(map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  result,
	})
}

func (s *codexAppSession) send(msg map[string]interface{}) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = s.stdin.Write(data)
	return err
}

func nestedString(root map[string]interface{}, keys ...string) string {
	cur := root
	for i, key := range keys {
		if i == len(keys)-1 {
			v, _ := cur[key].(string)
			return v
		}
		next, _ := cur[key].(map[string]interface{})
		if next == nil {
			return ""
		}
		cur = next
	}
	return ""
}

type codexSteerWriter struct {
	session *codexAppSession
}

func (w *codexSteerWriter) Write(p []byte) (int, error) {
	if err := w.session.Steer(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (w *codexSteerWriter) Close() error {
	return nil
}
