// Package loopmanager tracks running loop processes, owning PTY sessions and output streaming.
package loopmanager

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
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
	workdir    string
	attempt    int
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
func (m *Manager) StartLoopWithAdapter(ctx context.Context, loopID, agentType, role, workdir, taskDesc string, attempt int) error {
	m.mu.Lock()
	if _, exists := m.loops[loopID]; exists {
		m.mu.Unlock()
		return fmt.Errorf("loop %s already running", loopID)
	}
	m.mu.Unlock()

	if attempt < 1 {
		attempt = 1
	}

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

	proc, err := ag.Start(workdir, task, map[string]string{
		"loop_id": loopID,
		"role":    role,
		"workdir": workdir,
	})
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
		workdir:    workdir,
		attempt:    attempt,
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
		defer func() {
			if err := m.closeAdapterProcess(lp); err != nil {
				log.Printf("Failed to close adapter process for loop %s: %v", loopID, err)
			}
			m.mu.Lock()
			delete(m.loops, loopID)
			m.mu.Unlock()
		}()

		result, waitErr := ag.Wait(proc)

		sessionID := ag.SessionID(proc)

		if waitErr != nil {
			_ = m.sendFunc("error", map[string]interface{}{
				"loop_id":     loopID,
				"message":     fmt.Sprintf("agent wait error: %v", waitErr),
				"recoverable": true,
			})
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
				attemptPayload := map[string]interface{}{
					"loop_id":    loopID,
					"exit_code":  result.ExitCode,
					"session_id": sessionID,
				}

				if role == "checker" {
					expectedJSONPath, expectedFeedbackPath :=
						expectedCheckerHandoffPaths(loopID, lp.attempt)
					attemptPayload["expected_handoff_json_path"] = expectedJSONPath
					attemptPayload["expected_handoff_feedback_path"] = expectedFeedbackPath
					attemptPayload["attempt"] = lp.attempt

					verdict, feedbackPath, feedback, parseErr :=
						loadCheckerHandoff(loopID, lp.attempt)
					if parseErr != nil {
						_ = m.sendFunc("error", map[string]interface{}{
							"loop_id":     loopID,
							"message":     fmt.Sprintf("checker handoff parse error: %v", parseErr),
							"recoverable": true,
						})
						attemptPayload["handoff_valid"] = false
						attemptPayload["handoff_error"] = parseErr.Error()
						attemptPayload["verdict"] = "fail"
						attemptPayload["feedback"] =
							"Checker did not produce required handoff JSON/markdown files."
					} else {
						attemptPayload["handoff_valid"] = true
						attemptPayload["verdict"] = verdict
						attemptPayload["feedback_path"] = feedbackPath
						attemptPayload["feedback"] = feedback
					}
				}

				_ = m.sendFunc("attempt_complete", attemptPayload)
			}
		}

	}()

	// If the agent is a TUI (no -p flag mode), type the prompt
	if strings.TrimSpace(proc.InitialPrompt) != "" {
		writeFn := func(data []byte) error {
			return ag.SendInput(proc, data)
		}
		go typePromptToTUI(done, &lastOutput, loopID, proc.InitialPrompt, writeFn)
	}

	_ = writer

	log.Printf("Started adapter loop %s: %s (role=%s)", loopID, agentType, role)
	return nil
}

type checkerHandoff struct {
	VERDICT  string `json:"VERDICT"`
	FEEDBACK string `json:"FEEDBACK"`
}

func globalAlgedoniaDir() string {
	if custom := strings.TrimSpace(os.Getenv("ALGEDONIA_HOME")); custom != "" {
		return filepath.Clean(custom)
	}
	home, err := os.UserHomeDir()
	if err == nil && strings.TrimSpace(home) != "" {
		return filepath.Join(home, ".algedonia")
	}
	return filepath.Clean(".algedonia")
}

func checkerHandoffSuffix(loopID string, attempt int) string {
	return filepath.ToSlash(filepath.Join(".algedonia", "handoffs", loopID, fmt.Sprintf("attempt-%d", attempt), "checker_feedback.md"))
}

func expectedCheckerHandoffPaths(loopID string, attempt int) (string, string) {
	base := filepath.Join(globalAlgedoniaDir(), "handoffs", loopID, fmt.Sprintf("attempt-%d", attempt))
	return filepath.Join(base, "checker_result.json"), filepath.Join(base, "checker_feedback.md")
}

func loadCheckerHandoff(loopID string, attempt int) (string, string, string, error) {
	handoffPath, expectedFeedbackPath := expectedCheckerHandoffPaths(loopID, attempt)
	raw, err := os.ReadFile(handoffPath)
	if err != nil {
		return "", "", "", fmt.Errorf("read %s: %w", handoffPath, err)
	}

	var handoff checkerHandoff
	if err := json.Unmarshal(raw, &handoff); err != nil {
		return "", "", "", fmt.Errorf("decode checker handoff json: %w", err)
	}

	verdict := strings.ToLower(strings.TrimSpace(handoff.VERDICT))
	if verdict != "pass" && verdict != "fail" {
		return "", "", "", fmt.Errorf("invalid VERDICT %q", handoff.VERDICT)
	}

	feedbackPath := strings.TrimSpace(handoff.FEEDBACK)
	if feedbackPath == "" {
		return "", "", "", fmt.Errorf("missing FEEDBACK path")
	}

	absFeedbackPath := strings.TrimSpace(feedbackPath)
	if strings.HasPrefix(absFeedbackPath, "~/") {
		home, err := os.UserHomeDir()
		if err == nil && strings.TrimSpace(home) != "" {
			absFeedbackPath = filepath.Join(home, absFeedbackPath[2:])
		}
	}
	if !filepath.IsAbs(absFeedbackPath) {
		absFeedbackPath = filepath.Join(globalAlgedoniaDir(), absFeedbackPath)
	}
	absFeedbackPath = filepath.Clean(absFeedbackPath)
	expectedFeedbackPath = filepath.Clean(expectedFeedbackPath)
	if absFeedbackPath != expectedFeedbackPath &&
		!strings.HasSuffix(filepath.ToSlash(absFeedbackPath), checkerHandoffSuffix(loopID, attempt)) {
		return "", "", "", fmt.Errorf("FEEDBACK path must be %s", filepath.Clean(expectedFeedbackPath))
	}

	markdown, err := os.ReadFile(absFeedbackPath)
	if err != nil {
		return "", "", "", fmt.Errorf("read FEEDBACK markdown %s: %w", absFeedbackPath, err)
	}

	feedback := strings.TrimSpace(string(markdown))
	if feedback == "" {
		return "", "", "", fmt.Errorf("FEEDBACK markdown is empty at %s", absFeedbackPath)
	}

	return verdict, filepath.Clean(absFeedbackPath), feedback, nil
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
			agentType = "codex"
		}
		attempt := parseAttempt(payload["attempt"])
		workdir, _ := payload["workdir"].(string)
		if workdir == "" {
			workdir = m.repoRoot
		}
		taskDesc, _ := payload["task"].(string)
		return m.StartLoopWithAdapter(ctx, loopID, agentType, role, workdir, taskDesc, attempt)
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

func parseAttempt(raw interface{}) int {
	switch v := raw.(type) {
	case int:
		return v
	case int32:
		return int(v)
	case int64:
		return int(v)
	case float64:
		return int(v)
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(v))
		if err == nil {
			return parsed
		}
	}
	return 1
}

func (m *Manager) closeAdapterProcess(lp *LoopProcess) error {
	if lp == nil || lp.adapter == nil || lp.process == nil {
		return nil
	}

	// Codex app-server stays alive after turn completion; close it to avoid leaked processes.
	if _, ok := lp.adapter.(*adapter.CodexAdapter); ok {
		return lp.adapter.Kill(lp.process)
	}

	return nil
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
