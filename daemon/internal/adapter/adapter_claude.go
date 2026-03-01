package adapter

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"

	ptyPkg "github.com/algedonia/daemon/internal/pty"
)

// Compile-time interface check.
var _ AgentAdapter = (*ClaudeCodeAdapter)(nil)

// ClaudeCodeAdapter implements AgentAdapter for Claude Code CLI.
type ClaudeCodeAdapter struct{}

// Start spawns claude in interactive TUI mode.
func (a *ClaudeCodeAdapter) Start(workdir string, task string, config map[string]string) (*Process, error) {
	args := []string{"--dangerously-skip-permissions", "--verbose"}

	cmd := exec.Command("claude", args...)
	cmd.Dir = workdir
	cmd.Env = os.Environ()

	loopID := strings.TrimSpace(config["loop_id"])
	role := strings.TrimSpace(config["role"])
	if loopID != "" {
		cmd.Env = append(cmd.Env, "ALGEDONIA_LOOP_ID="+loopID)
	}
	if role != "" {
		cmd.Env = append(cmd.Env, "ALGEDONIA_ROLE="+role)
	}
	if workdir != "" {
		cmd.Env = append(cmd.Env, "ALGEDONIA_WORKDIR="+workdir)
	}

	sess, err := allocatePTY(cmd)
	if err != nil {
		return nil, fmt.Errorf("starting claude: %w", err)
	}

	collector := newOutputCollector()
	sessionID := uuid.New().String()
	completionMarker := ""
	if loopID != "" {
		completionMarker = filepath.Join(workdir, ".algedonia", "runtime", loopID, "attempt_complete.json")
		_ = os.Remove(completionMarker)
	}

	return &Process{
		ID:               sessionID,
		SessionID:        sessionID,
		Workdir:          workdir,
		LoopID:           loopID,
		Role:             role,
		InitialPrompt:    task,
		session:          sess,
		collector:        collector,
		completionMarker: completionMarker,
	}, nil
}

// AttachPTY returns the PTY reader and writer for streaming.
func (a *ClaudeCodeAdapter) AttachPTY(process *Process) (io.Reader, io.WriteCloser, error) {
	if process.session == nil {
		return nil, nil, fmt.Errorf("process has no PTY session")
	}
	return process.session.Reader(), &sessionWriter{session: process.session}, nil
}

// SendInput writes data to the process PTY.
func (a *ClaudeCodeAdapter) SendInput(process *Process, data []byte) error {
	if process.session == nil {
		return fmt.Errorf("process has no PTY session")
	}
	_, err := process.session.Write(data)
	return err
}

// Wait blocks until the process exits and returns the result.
func (a *ClaudeCodeAdapter) Wait(process *Process) (*ExitResult, error) {
	return WaitWithCompletionMarker(process, func() (int, error) {
		return waitProcess(process.session)
	})
}

// Kill terminates the process with SIGTERM then SIGKILL.
func (a *ClaudeCodeAdapter) Kill(process *Process) error {
	return killProcess(process.session, 5*time.Second)
}

// Resize updates PTY dimensions.
func (a *ClaudeCodeAdapter) Resize(process *Process, cols, rows uint16) error {
	if process.session == nil {
		return fmt.Errorf("process has no PTY session")
	}
	if cols == 0 || rows == 0 {
		return nil
	}
	return process.session.SetSize(rows, cols)
}

// SessionID returns the session identifier.
func (a *ClaudeCodeAdapter) SessionID(process *Process) string {
	return process.SessionID
}

// sessionWriter wraps a pty.Session to implement io.WriteCloser.
type sessionWriter struct {
	session *ptyPkg.Session
}

func (w *sessionWriter) Write(p []byte) (int, error) {
	return w.session.Write(p)
}

func (w *sessionWriter) Close() error {
	return nil // PTY close is handled by Kill/Wait
}
