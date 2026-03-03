package adapter

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/algedonia/daemon/internal/runtimepath"
	"github.com/google/uuid"
)

// Compile-time interface check.
var _ AgentAdapter = (*CodexAdapter)(nil)

// CodexAdapter implements AgentAdapter for the Codex CLI in TUI mode.
type CodexAdapter struct{}

// Start spawns codex in interactive TUI mode.
func (a *CodexAdapter) Start(workdir string, task string, config map[string]string) (*Process, error) {
	args := []string{"--dangerously-bypass-approvals-and-sandbox"}
	if model := strings.TrimSpace(config["model"]); model != "" {
		args = append(args, "--model", model)
	}
	if effort := strings.TrimSpace(config["effort"]); effort != "" {
		args = append(args, "-c", fmt.Sprintf("model_reasoning_effort=%q", effort))
	}

	cmd := exec.Command("codex", args...)
	cmd.Dir = workdir
	cmd.Env = os.Environ()

	loopID := strings.TrimSpace(config["loop_id"])
	role := strings.TrimSpace(config["role"])
	workspaceSlug := strings.TrimSpace(config["workspace_slug"])
	if workspaceSlug == "" {
		return nil, fmt.Errorf("workspace_slug is required (sets ALGEDONIA_WORKSPACE)")
	}
	runtimeDir, err := runtimepath.WorkspaceRuntimeDir(workspaceSlug)
	if err != nil {
		return nil, fmt.Errorf("resolving workspace runtime dir: %w", err)
	}
	if loopID != "" {
		cmd.Env = append(cmd.Env, "ALGEDONIA_LOOP_ID="+loopID)
	}
	if role != "" {
		cmd.Env = append(cmd.Env, "ALGEDONIA_ROLE="+role)
	}
	cmd.Env = append(cmd.Env, "ALGEDONIA_WORKSPACE="+workspaceSlug)
	cmd.Env = append(cmd.Env, "ALGEDONIA_WORKSPACE_SLUG="+workspaceSlug)
	cmd.Env = append(cmd.Env, "ALGEDONIA_RUNTIME_DIR="+runtimeDir)
	if workdir != "" {
		cmd.Env = append(cmd.Env, "ALGEDONIA_WORKDIR="+workdir)
	}

	sess, err := allocatePTY(cmd)
	if err != nil {
		return nil, fmt.Errorf("starting codex: %w", err)
	}

	collector := newOutputCollector()
	sessionID := uuid.New().String()
	completionMarker := ""
	if loopID != "" {
		completionMarker = filepath.Join(runtimeDir, loopID, "attempt_complete.json")
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

// AttachPTY returns a reader and writer stream for terminal UX.
func (a *CodexAdapter) AttachPTY(process *Process) (io.Reader, io.WriteCloser, error) {
	if process.session == nil {
		return nil, nil, fmt.Errorf("process has no PTY session")
	}
	return process.session.Reader(), &sessionWriter{session: process.session}, nil
}

// SendInput writes user steering input.
func (a *CodexAdapter) SendInput(process *Process, data []byte) error {
	if process.session == nil {
		return fmt.Errorf("process has no PTY session")
	}
	_, err := process.session.Write(data)
	return err
}

// Wait blocks until completion.
func (a *CodexAdapter) Wait(process *Process) (*ExitResult, error) {
	return WaitWithCompletionMarker(process, func() (int, error) {
		return waitProcess(process.session)
	})
}

// Kill terminates the process.
func (a *CodexAdapter) Kill(process *Process) error {
	return killProcess(process.session, 5*time.Second)
}

// Resize updates PTY dimensions.
func (a *CodexAdapter) Resize(process *Process, cols, rows uint16) error {
	if process.session == nil {
		return fmt.Errorf("process has no PTY session")
	}
	if cols == 0 || rows == 0 {
		return nil
	}
	return process.session.SetSize(rows, cols)
}

// SessionID returns the session identifier.
func (a *CodexAdapter) SessionID(process *Process) string {
	return process.SessionID
}
