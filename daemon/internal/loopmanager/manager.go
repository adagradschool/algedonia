// Package loopmanager tracks running loop processes, owning PTY sessions and output streaming.
package loopmanager

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	ptyPkg "github.com/algedonia/daemon/internal/pty"
)

// LoopProcess represents a running loop with its PTY session and chunker.
type LoopProcess struct {
	LoopID  string
	Session *ptyPkg.Session
	Chunker *Chunker
	Cancel  context.CancelFunc
	Done    chan struct{}
}

// Manager tracks running loop processes and streams their output.
type Manager struct {
	mu       sync.Mutex
	loops    map[string]*LoopProcess
	sendFunc func(event string, payload map[string]interface{}) error
}

// NewManager creates a Manager that uses sendFunc to send events to the server.
func NewManager(sendFunc func(event string, payload map[string]interface{}) error) *Manager {
	return &Manager{
		loops:    make(map[string]*LoopProcess),
		sendFunc: sendFunc,
	}
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
	// lastOutput tracks when the last PTY output was received,
	// used to detect when the TUI has finished rendering (idle).
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

	// Write prompt to the TUI once it's idle (done rendering).
	// Claude Code is an Ink-based TUI — we detect readiness by waiting for
	// the output stream to go quiet (no new output for idleThreshold),
	// meaning the splash screen has finished and the input prompt is ready.
	// Then we type characters into the PTY and submit with \r (carriage return).
	if prompt != "" {
		go func() {
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

			// Type each character individually with a small delay,
			// simulating real keyboard input for the TUI.
			for _, ch := range []byte(prompt) {
				if _, err := sess.Write([]byte{ch}); err != nil {
					log.Printf("Failed to type char to loop %s: %v", loopID, err)
					return
				}
				time.Sleep(5 * time.Millisecond)
			}

			// Let the TUI process all the typed text
			time.Sleep(300 * time.Millisecond)

			// Submit with carriage return (equivalent to tmux's C-m / Ctrl+M)
			if _, err := sess.Write([]byte("\r")); err != nil {
				log.Printf("Failed to send Enter to loop %s: %v", loopID, err)
			}

			log.Printf("Prompt submitted for loop %s", loopID)
		}()
	}

	log.Printf("Started loop %s: %s %v", loopID, command, args)
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
