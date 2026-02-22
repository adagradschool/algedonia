package adapter

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"

	"github.com/google/uuid"
)

// Compile-time interface check.
var _ AgentAdapter = (*CodexAdapter)(nil)

// CodexAdapter implements AgentAdapter for the Codex CLI.
type CodexAdapter struct{}

// Start spawns codex with --full-auto.
func (a *CodexAdapter) Start(workdir string, task string, config map[string]string) (*Process, error) {
	args := []string{"--full-auto"}
	if task != "" {
		args = append(args, task)
	}

	cmd := exec.Command("codex", args...)
	cmd.Dir = workdir
	cmd.Env = os.Environ()

	sess, err := allocatePTY(cmd)
	if err != nil {
		return nil, fmt.Errorf("starting codex: %w", err)
	}

	collector := newOutputCollector()
	sessionID := uuid.New().String()

	return &Process{
		ID:        sessionID,
		SessionID: sessionID,
		Workdir:   workdir,
		session:   sess,
		collector: collector,
	}, nil
}

// AttachPTY returns the PTY reader and writer for streaming.
func (a *CodexAdapter) AttachPTY(process *Process) (io.Reader, io.WriteCloser, error) {
	if process.session == nil {
		return nil, nil, fmt.Errorf("process has no PTY session")
	}
	return process.session.Reader(), &sessionWriter{session: process.session}, nil
}

// SendInput writes data to the process PTY.
func (a *CodexAdapter) SendInput(process *Process, data []byte) error {
	if process.session == nil {
		return fmt.Errorf("process has no PTY session")
	}
	_, err := process.session.Write(data)
	return err
}

// Wait blocks until the process exits and returns the result.
func (a *CodexAdapter) Wait(process *Process) (*ExitResult, error) {
	exitCode, err := waitProcess(process.session)
	if err != nil {
		return nil, err
	}
	return &ExitResult{
		ExitCode:  exitCode,
		SessionID: process.SessionID,
		Output:    process.collector.Bytes(),
	}, nil
}

// Kill terminates the process with SIGTERM then SIGKILL.
func (a *CodexAdapter) Kill(process *Process) error {
	return killProcess(process.session, 5*time.Second)
}

// SessionID returns the session identifier.
func (a *CodexAdapter) SessionID(process *Process) string {
	return process.SessionID
}
