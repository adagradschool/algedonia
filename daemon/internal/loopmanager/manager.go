// Package loopmanager tracks running loop processes, owning PTY sessions and output streaming.
package loopmanager

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
	ptyPkg "github.com/algedonia/daemon/internal/pty"
)

// LoopProcess represents a running loop with its PTY session and chunker.
type LoopProcess struct {
	LoopID  string
	Session *ptyPkg.Session
	Chunker *Chunker
	Cancel  context.CancelFunc
	Done    chan struct{}

	// adapter fields — set when started via StartLoopWithAdapter
	adapter    adapter.AgentAdapter
	process    *adapter.Process
	role       string
	promptsDir string
}

// Manager tracks running loop processes and streams their output.
type Manager struct {
	mu         sync.Mutex
	loops      map[string]*LoopProcess
	sendFunc   func(event string, payload map[string]interface{}) error
	adapterReg *adapter.Registry
	repoRoot   string
}

// NewManager creates a Manager that uses sendFunc to send events to the server.
func NewManager(sendFunc func(event string, payload map[string]interface{}) error, registry *adapter.Registry, repoRoot string) *Manager {
	return &Manager{
		loops:      make(map[string]*LoopProcess),
		sendFunc:   sendFunc,
		adapterReg: registry,
		repoRoot:   repoRoot,
	}
}

// typePromptToTUI waits for the TUI to become idle, then types the prompt
// and submits with carriage return. writeFn writes bytes to the PTY.
func typePromptToTUI(done <-chan struct{}, lastOutput *atomic.Int64, loopID, prompt string, writeFn func([]byte) error) {
	const idleThreshold = 1500 * time.Millisecond
	const pollInterval = 100 * time.Millisecond
	const maxWait = 30 * time.Second

	deadline := time.After(maxWait)
	// Wait at least 2 seconds before even checking for idle
	time.Sleep(2 * time.Second)

	for {
		select {
		case <-done:
			return
		case <-deadline:
			log.Printf("Timed out waiting for idle on loop %s, sending prompt anyway", loopID)
			goto send
		case <-time.After(pollInterval):
			elapsedMs := time.Now().UnixMilli() - lastOutput.Load()
			if elapsedMs >= idleThreshold.Milliseconds() {
				log.Printf("TUI idle for %dms on loop %s, sending prompt", elapsedMs, loopID)
				goto send
			}
		}
	}

send:
	log.Printf("Typing prompt into loop %s (%d bytes)", loopID, len(prompt))

	for _, ch := range []byte(prompt) {
		if err := writeFn([]byte{ch}); err != nil {
			log.Printf("Failed to type char to loop %s: %v", loopID, err)
			return
		}
		time.Sleep(5 * time.Millisecond)
	}

	// Let the TUI process all the typed text
	time.Sleep(300 * time.Millisecond)

	// Submit with carriage return
	if err := writeFn([]byte("\r")); err != nil {
		log.Printf("Failed to send Enter to loop %s: %v", loopID, err)
	}

	log.Printf("Prompt submitted for loop %s", loopID)
}

// StartLoop spawns a process in a PTY and streams output to the server.
// If prompt is non-empty, it is written to the process stdin after startup.
func (m *Manager) StartLoop(ctx context.Context, loopID, command string, args []string, workdir, prompt string) error {
	m.mu.Lock()
	if _, exists := m.loops[loopID]; exists {
		m.mu.Unlock()
		return fmt.Errorf("loop %s already running", loopID)
	}
	m.mu.Unlock()

	loopCtx, cancel := context.WithCancel(ctx)

	cmd := exec.CommandContext(loopCtx, command, args...)
	if workdir != "" {
		cmd.Dir = workdir
	}

	sess, err := ptyPkg.Start(cmd)
	if err != nil {
		cancel()
		return fmt.Errorf("starting pty for loop %s: %w", loopID, err)
	}

	done := make(chan struct{})
	var lastOutput atomic.Int64
	lastOutput.Store(time.Now().UnixMilli())

	chunker := NewChunker(50*time.Millisecond, 4096, func(data []byte) {
		encoded := base64.StdEncoding.EncodeToString(data)
		if err := m.sendFunc("terminal_output", map[string]interface{}{
			"loop_id": loopID,
			"data":    encoded,
		}); err != nil {
			log.Printf("Failed to send terminal_output for loop %s: %v", loopID, err)
		}
	})

	lp := &LoopProcess{
		LoopID:  loopID,
		Session: sess,
		Chunker: chunker,
		Cancel:  cancel,
		Done:    done,
	}

	m.mu.Lock()
	m.loops[loopID] = lp
	m.mu.Unlock()

	// Output reader goroutine
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := sess.Reader().Read(buf)
			if n > 0 {
				lastOutput.Store(time.Now().UnixMilli())
				chunker.Write(buf[:n])
			}
			if err != nil {
				if err != io.EOF {
					log.Printf("PTY read error for loop %s: %v", loopID, err)
				}
				break
			}
		}
		chunker.Close()
	}()

	// Wait goroutine — detects process exit
	go func() {
		defer close(done)
		waitErr := sess.Wait()
		sess.Close()

		exitCode := 0
		if waitErr != nil {
			if exitErr, ok := waitErr.(*exec.ExitError); ok {
				exitCode = exitErr.ExitCode()
			} else {
				exitCode = -1
			}
		}

		if err := m.sendFunc("loop_exited", map[string]interface{}{
			"loop_id":   loopID,
			"exit_code": exitCode,
		}); err != nil {
			log.Printf("Failed to send loop_exited for loop %s: %v", loopID, err)
		}

		m.mu.Lock()
		delete(m.loops, loopID)
		m.mu.Unlock()
	}()

	if prompt != "" {
		writeFn := func(data []byte) error {
			_, err := sess.Write(data)
			return err
		}
		go typePromptToTUI(done, &lastOutput, loopID, prompt, writeFn)
	}

	log.Printf("Started loop %s: %s %v", loopID, command, args)
	return nil
}

// StartLoopWithAdapter spawns a loop using a registered adapter.
func (m *Manager) StartLoopWithAdapter(ctx context.Context, loopID, agentType, role, workdir, taskDesc string) error {
	m.mu.Lock()
	if _, exists := m.loops[loopID]; exists {
		m.mu.Unlock()
		return fmt.Errorf("loop %s already running", loopID)
	}
	m.mu.Unlock()

	ag, err := m.adapterReg.Get(agentType)
	if err != nil {
		return fmt.Errorf("resolving adapter for loop %s: %w", loopID, err)
	}

	// Load prompt for the role
	promptsDir := filepath.Join(workdir, ".algedonia", "prompts")
	systemPrompt, err := adapter.LoadPrompt(promptsDir, role)
	if err != nil {
		log.Printf("Warning: could not load prompt for role %q: %v", role, err)
		systemPrompt = ""
	}

	// Construct task string
	task := taskDesc
	if systemPrompt != "" {
		task = systemPrompt + "\n\n---\n\n" + taskDesc
	}
	if role == "decompose" {
		task += "\n\nIMPORTANT: Output your DAG as JSON between these exact delimiters:\n---ALGEDONIA_DAG_BEGIN---\n<your JSON here>\n---ALGEDONIA_DAG_END---"
	}

	proc, err := ag.Start(workdir, task, nil)
	if err != nil {
		return fmt.Errorf("starting adapter for loop %s: %w", loopID, err)
	}

	reader, writer, err := ag.AttachPTY(proc)
	if err != nil {
		ag.Kill(proc)
		return fmt.Errorf("attaching pty for loop %s: %w", loopID, err)
	}

	_, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	var lastOutput atomic.Int64
	lastOutput.Store(time.Now().UnixMilli())

	chunker := NewChunker(50*time.Millisecond, 4096, func(data []byte) {
		encoded := base64.StdEncoding.EncodeToString(data)
		if err := m.sendFunc("terminal_output", map[string]interface{}{
			"loop_id": loopID,
			"data":    encoded,
		}); err != nil {
			log.Printf("Failed to send terminal_output for loop %s: %v", loopID, err)
		}
	})

	lp := &LoopProcess{
		LoopID:     loopID,
		Chunker:    chunker,
		Cancel:     cancel,
		Done:       done,
		adapter:    ag,
		process:    proc,
		role:       role,
		promptsDir: promptsDir,
	}

	m.mu.Lock()
	m.loops[loopID] = lp
	m.mu.Unlock()

	// Output reader goroutine — dual-write to chunker and output collector
	go func() {
		// Use TeeReader to write to both the chunker (streaming) and the collector (post-exit parsing)
		tee := io.TeeReader(reader, proc.Collector())
		buf := make([]byte, 4096)
		for {
			n, err := tee.Read(buf)
			if n > 0 {
				lastOutput.Store(time.Now().UnixMilli())
				chunker.Write(buf[:n])
			}
			if err != nil {
				if err != io.EOF {
					log.Printf("PTY read error for loop %s: %v", loopID, err)
				}
				break
			}
		}
		chunker.Close()
	}()

	// Wait goroutine — handles result based on role
	go func() {
		defer close(done)
		result, waitErr := ag.Wait(proc)

		sessionID := ag.SessionID(proc)

		if waitErr != nil {
			_ = m.sendFunc("error", map[string]interface{}{
				"loop_id":     loopID,
				"message":     fmt.Sprintf("agent wait error: %v", waitErr),
				"recoverable": true,
			})
			m.mu.Lock()
			delete(m.loops, loopID)
			m.mu.Unlock()
			return
		}

		switch role {
		case "decompose":
			dag, parseErr := adapter.ParseDAGOutput(result.Output)
			if parseErr != nil {
				_ = m.sendFunc("error", map[string]interface{}{
					"loop_id":     loopID,
					"message":     fmt.Sprintf("decompose output parse error: %v", parseErr),
					"recoverable": true,
				})
			} else {
				_ = m.sendFunc("loop_result", map[string]interface{}{
					"loop_id":    loopID,
					"verdict":    "pass",
					"dag":        dag,
					"session_id": sessionID,
				})
			}
		default:
			if result.ExitCode != 0 {
				_ = m.sendFunc("error", map[string]interface{}{
					"loop_id":     loopID,
					"message":     fmt.Sprintf("agent exited with code %d", result.ExitCode),
					"recoverable": true,
				})
			} else {
				_ = m.sendFunc("attempt_complete", map[string]interface{}{
					"loop_id":    loopID,
					"exit_code":  result.ExitCode,
					"session_id": sessionID,
				})
			}
		}

		m.mu.Lock()
		delete(m.loops, loopID)
		m.mu.Unlock()
	}()

	// If the agent is a TUI (no -p flag mode), type the prompt
	// For now, adapters use -p flag so no TUI typing needed
	_ = writer

	log.Printf("Started adapter loop %s: %s (role=%s)", loopID, agentType, role)
	return nil
}

// StopLoop sends SIGTERM to the process, then SIGKILL after 5 seconds.
func (m *Manager) StopLoop(loopID, reason string) error {
	m.mu.Lock()
	lp, exists := m.loops[loopID]
	m.mu.Unlock()

	if !exists {
		return fmt.Errorf("loop %s not found", loopID)
	}

	log.Printf("Stopping loop %s: %s", loopID, reason)

	// Adapter-managed process
	if lp.adapter != nil {
		err := lp.adapter.Kill(lp.process)
		<-lp.Done
		return err
	}

	// Raw PTY process
	pid := lp.Session.Pid()
	if pid > 0 {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}

	select {
	case <-lp.Done:
		return nil
	case <-time.After(5 * time.Second):
		log.Printf("Loop %s did not exit after SIGTERM, sending SIGKILL", loopID)
		if pid > 0 {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
		lp.Cancel()
		<-lp.Done
		return nil
	}
}

// RunningCount returns the number of currently running loops.
func (m *Manager) RunningCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.loops)
}

// HandleStartLoop is a command handler for "start_loop" events from the server.
func (m *Manager) HandleStartLoop(ctx context.Context, payload map[string]interface{}) error {
	loopID, _ := payload["loop_id"].(string)
	if loopID == "" {
		return fmt.Errorf("missing loop_id in start_loop payload")
	}

	// If a role is specified, route through adapter path
	role, _ := payload["role"].(string)
	if role != "" {
		agentType, _ := payload["agent_type"].(string)
		if agentType == "" {
			agentType = "claude_code"
		}
		workdir, _ := payload["workdir"].(string)
		if workdir == "" {
			workdir = m.repoRoot
		}
		taskDesc, _ := payload["task"].(string)
		return m.StartLoopWithAdapter(ctx, loopID, agentType, role, workdir, taskDesc)
	}

	// Legacy raw-process path
	command, _ := payload["command"].(string)
	if command == "" {
		command = "claude"
	}

	var args []string
	if rawArgs, ok := payload["args"].([]interface{}); ok {
		for _, a := range rawArgs {
			if s, ok := a.(string); ok {
				args = append(args, s)
			}
		}
	}
	if len(args) == 0 && command == "claude" {
		args = []string{"--dangerously-skip-permissions"}
	}

	workdir, _ := payload["workdir"].(string)

	prompt, _ := payload["prompt"].(string)
	if prompt == "" && command == "claude" {
		prompt = "Say hello and describe what you see in this repo"
	}

	return m.StartLoop(ctx, loopID, command, args, workdir, prompt)
}

// SendInput writes raw bytes to the PTY stdin of a running loop.
func (m *Manager) SendInput(loopID string, data []byte) error {
	m.mu.Lock()
	lp, exists := m.loops[loopID]
	m.mu.Unlock()
	if !exists {
		return fmt.Errorf("loop %s not found", loopID)
	}

	// Adapter-managed process
	if lp.adapter != nil {
		return lp.adapter.SendInput(lp.process, data)
	}

	// Raw PTY process
	_, err := lp.Session.Write(data)
	if err != nil {
		return fmt.Errorf("writing stdin to loop %s: %w", loopID, err)
	}
	return nil
}

// HandleStdinInput is a command handler for "stdin_input" events from the server.
func (m *Manager) HandleStdinInput(_ context.Context, payload map[string]interface{}) error {
	loopID, _ := payload["loop_id"].(string)
	if loopID == "" {
		return fmt.Errorf("missing loop_id in stdin_input payload")
	}
	dataStr, _ := payload["data"].(string)
	if dataStr == "" {
		return nil
	}
	data, err := base64.StdEncoding.DecodeString(dataStr)
	if err != nil {
		return fmt.Errorf("decoding stdin_input base64: %w", err)
	}
	return m.SendInput(loopID, data)
}

// HandleStopLoop is a command handler for "stop_loop" events from the server.
func (m *Manager) HandleStopLoop(_ context.Context, payload map[string]interface{}) error {
	loopID, _ := payload["loop_id"].(string)
	if loopID == "" {
		return fmt.Errorf("missing loop_id in stop_loop payload")
	}

	reason, _ := payload["reason"].(string)
	if reason == "" {
		reason = "server requested stop"
	}

	return m.StopLoop(loopID, reason)
}
