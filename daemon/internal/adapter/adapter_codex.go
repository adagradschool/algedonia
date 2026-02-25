package adapter

import (
	"fmt"
	"io"
	"time"

	"github.com/google/uuid"
)

// Compile-time interface check.
var _ AgentAdapter = (*CodexAdapter)(nil)

// CodexAdapter implements AgentAdapter for the Codex CLI in app-server mode.
type CodexAdapter struct{}

// Start spawns codex and starts a task turn.
func (a *CodexAdapter) Start(workdir string, task string, config map[string]string) (*Process, error) {
	sessionID := uuid.New().String()
	collector := newOutputCollector()

	app, err := startCodexAppServer(workdir, task, sessionID, collector)
	if err != nil {
		return nil, fmt.Errorf("starting codex app-server session: %w", err)
	}

	return &Process{
		ID:        sessionID,
		SessionID: sessionID,
		Workdir:   workdir,
		collector: collector,
		app:       app,
	}, nil
}

// AttachPTY returns a reader and writer stream for terminal UX.
func (a *CodexAdapter) AttachPTY(process *Process) (io.Reader, io.WriteCloser, error) {
	if process.app == nil {
		return nil, nil, fmt.Errorf("process has no app-server session")
	}
	return process.app.Attach()
}

// SendInput writes user steering input.
func (a *CodexAdapter) SendInput(process *Process, data []byte) error {
	if process.app == nil {
		return fmt.Errorf("process has no app-server session")
	}
	return process.app.Steer(data)
}

// Wait blocks until completion.
func (a *CodexAdapter) Wait(process *Process) (*ExitResult, error) {
	if process.app == nil {
		return nil, fmt.Errorf("process has no app-server session")
	}
	return process.app.Wait()
}

// Kill terminates the process.
func (a *CodexAdapter) Kill(process *Process) error {
	if process.app == nil {
		return fmt.Errorf("process has no app-server session")
	}
	return process.app.Kill(5 * time.Second)
}

// SessionID returns the session identifier.
func (a *CodexAdapter) SessionID(process *Process) string {
	return process.SessionID
}
