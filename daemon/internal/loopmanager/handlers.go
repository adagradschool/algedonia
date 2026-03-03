package loopmanager

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/algedonia/daemon/internal/repo"
)

// HandleStartLoop is a command handler for "start_loop" events from the server.
func (m *Manager) HandleStartLoop(ctx context.Context, payload map[string]interface{}) error {
	loopID := payloadStr(payload, "loop_id")
	if loopID == "" {
		return fmt.Errorf("missing loop_id in start_loop payload")
	}

	// Overview role uses headless pipe mode for fast generation
	role := payloadStr(payload, "role")
	if role == "overview" {
		return m.StartOverviewLoop(ctx, loopID, payloadStr(payload, "task"), payloadStr(payload, "model"))
	}

	// If a role is specified, route through adapter path
	if role != "" {
		agentType := payloadStr(payload, "agent_type")
		if agentType == "" {
			agentType = defaultCodingAgent()
		}
		attempt := parseAttempt(payload["attempt"])
		wsSlug := payloadStr(payload, "workspace_slug")
		ticketID := payloadStr(payload, "ticket_id")

		workdir, workspaceDir, err := m.resolveScopedTicketWorkdir(ctx, wsSlug, ticketID)
		if err != nil {
			return fmt.Errorf("invalid start_loop scope: %w", err)
		}

		return m.StartLoopWithAdapter(ctx, loopID, agentType, role, workdir, workspaceDir, wsSlug,
			payloadStr(payload, "task"), payloadStr(payload, "model"), payloadStr(payload, "effort"), attempt)
	}

	// Legacy raw-process path
	command := payloadStr(payload, "command")
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

	workdir := payloadStr(payload, "workdir")
	prompt := payloadStr(payload, "prompt")

	return m.StartLoop(ctx, loopID, command, args, workdir, prompt)
}

// HandleStdinInput is a command handler for "stdin_input" events from the server.
func (m *Manager) HandleStdinInput(_ context.Context, payload map[string]interface{}) error {
	loopID := payloadStr(payload, "loop_id")
	if loopID == "" {
		return fmt.Errorf("missing loop_id in stdin_input payload")
	}
	dataStr := payloadStr(payload, "data")
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
	loopID := payloadStr(payload, "loop_id")
	if loopID == "" {
		return fmt.Errorf("missing loop_id in stop_loop payload")
	}

	reason := payloadStr(payload, "reason")
	if reason == "" {
		reason = "server requested stop"
	}

	return m.StopLoop(loopID, reason)
}

// HandleGetDiff runs `git diff HEAD` plus untracked-file patches in the loop's
// working directory and sends the result back to the server as a diff_result event.
func (m *Manager) HandleGetDiff(ctx context.Context, payload map[string]interface{}) error {
	loopID := payloadStr(payload, "loop_id")
	if loopID == "" {
		return fmt.Errorf("missing loop_id in get_diff payload")
	}

	workspaceSlug := payloadStr(payload, "workspace_slug")
	ticketID := payloadStr(payload, "ticket_id")
	workdir, _, err := m.resolveScopedTicketWorkdir(ctx, workspaceSlug, ticketID)
	if err != nil {
		return fmt.Errorf("invalid get_diff scope: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	out, err := collectGitDiff(ctx, workdir)

	result := map[string]interface{}{
		"loop_id": loopID,
	}

	if err != nil {
		result["error"] = fmt.Sprintf("git diff failed: %v", err)
		result["diff"] = ""
	} else {
		result["diff"] = out
	}

	m.sendEvent("diff_result", result)
	return nil
}

func collectGitDiff(ctx context.Context, workdir string) (string, error) {
	tracked, err := runGitOutput(ctx, workdir, false, "diff", "--binary", "HEAD")
	if err != nil {
		return "", fmt.Errorf("tracked diff: %w", err)
	}

	untrackedList, err := runGitOutput(ctx, workdir, false, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return "", fmt.Errorf("list untracked: %w", err)
	}

	var out bytes.Buffer
	out.Write(tracked)
	endsWithNewline := len(tracked) == 0 || tracked[len(tracked)-1] == '\n'

	nullPath := "/dev/null"
	if runtime.GOOS == "windows" {
		nullPath = "NUL"
	}

	for _, rawPath := range bytes.Split(untrackedList, []byte{0}) {
		if len(rawPath) == 0 {
			continue
		}

		patch, err := runGitOutput(
			ctx,
			workdir,
			true,
			"diff",
			"--binary",
			"--no-index",
			"--",
			nullPath,
			string(rawPath),
		)
		if err != nil {
			return "", fmt.Errorf("untracked diff for %q: %w", string(rawPath), err)
		}
		if len(patch) == 0 {
			continue
		}

		if out.Len() > 0 && !endsWithNewline {
			out.WriteByte('\n')
		}
		out.Write(patch)
		endsWithNewline = patch[len(patch)-1] == '\n'
	}

	return out.String(), nil
}

func runGitOutput(
	ctx context.Context,
	workdir string,
	allowExitCodeOne bool,
	args ...string,
) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = workdir

	if allowExitCodeOne {
		out, err := cmd.CombinedOutput()
		if err == nil {
			return out, nil
		}

		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
			return out, nil
		}

		msg := strings.TrimSpace(string(out))
		if msg != "" {
			return nil, fmt.Errorf("%w: %s", err, msg)
		}
		return nil, err
	}

	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			msg := strings.TrimSpace(string(exitErr.Stderr))
			if msg != "" {
				return nil, fmt.Errorf("%w: %s", err, msg)
			}
		}
		return nil, err
	}

	return out, nil
}

func (m *Manager) resolveScopedTicketWorkdir(ctx context.Context, workspaceSlug, ticketID string) (string, string, error) {
	if strings.TrimSpace(workspaceSlug) == "" || strings.TrimSpace(ticketID) == "" {
		return "", "", fmt.Errorf("missing workspace_slug or ticket_id")
	}
	if m.worktreeMgr == nil {
		return "", "", fmt.Errorf("worktree manager not configured")
	}

	workspaceDir := m.workdirForWorkspace(workspaceSlug)
	if workspaceDir == m.repoRoot {
		return "", "", fmt.Errorf("workspace base dir not configured for workspace %q", workspaceSlug)
	}

	workdir := m.resolveWorktree(ctx, workspaceDir, ticketID)
	expectedWorkdir := filepath.Join(workspaceDir, "worktrees", repo.TicketPrefix(ticketID))
	if filepath.Clean(workdir) != filepath.Clean(expectedWorkdir) {
		return "", "", fmt.Errorf("failed to resolve ticket worktree at %s", expectedWorkdir)
	}

	return workdir, workspaceDir, nil
}

// resolveWorktree resolves the working directory to a ticket-scoped worktree
// when a worktree manager is configured and a ticket_id is provided.
// Falls back to the workspace dir (or its root subdir) if no worktree can be created.
func (m *Manager) resolveWorktree(ctx context.Context, workdir, ticketID string) string {
	if ticketID == "" || m.worktreeMgr == nil || workdir == m.repoRoot {
		return workdir
	}
	prefix := repo.TicketPrefix(ticketID)
	wtPath, err := m.worktreeMgr.EnsureWorktree(ctx, workdir, prefix)
	if err != nil {
		log.Printf("Failed to create worktree for ticket %s: %v, falling back to workspace dir", ticketID, err)
		return workdir
	}
	log.Printf("Resolved worktree for ticket %s at %s", ticketID, wtPath)
	return wtPath
}

// HandleCleanupWorktree is a command handler for "cleanup_worktree" events.
// It removes the worktree associated with a ticket.
func (m *Manager) HandleCleanupWorktree(ctx context.Context, payload map[string]interface{}) error {
	ticketID := payloadStr(payload, "ticket_id")
	workspaceSlug := payloadStr(payload, "workspace_slug")

	if ticketID == "" || workspaceSlug == "" {
		return fmt.Errorf("missing ticket_id or workspace_slug in cleanup_worktree payload")
	}

	if m.worktreeMgr == nil {
		return nil
	}

	workdir := m.workdirForWorkspace(workspaceSlug)
	if workdir == m.repoRoot {
		return nil
	}

	prefix := repo.TicketPrefix(ticketID)
	if err := m.worktreeMgr.RemoveWorktree(ctx, workdir, prefix); err != nil {
		log.Printf("Failed to remove worktree for ticket %s: %v", ticketID, err)
		return err
	}

	log.Printf("Cleaned up worktree for ticket %s (prefix=%s)", ticketID, prefix)
	return nil
}

// HandleOpenEditor is a command handler for "open_editor" events.
// It opens the ticket's worktree (or workspace dir) in the user's editor.
func (m *Manager) HandleOpenEditor(ctx context.Context, payload map[string]interface{}) error {
	workspaceSlug := payloadStr(payload, "workspace_slug")
	ticketID := payloadStr(payload, "ticket_id")

	workdir := m.workdirForWorkspace(workspaceSlug)
	if ticketID != "" && m.worktreeMgr != nil && workdir != m.repoRoot {
		prefix := repo.TicketPrefix(ticketID)
		wtPath := filepath.Join(workdir, "worktrees", prefix)
		if info, err := os.Stat(wtPath); err == nil && info.IsDir() {
			workdir = wtPath
		}
	}

	cmd := openEditorCommand(ctx, workdir)
	return cmd.Start()
}

func openEditorCommand(ctx context.Context, workdir string) *exec.Cmd {
	editor := strings.TrimSpace(os.Getenv("EDITOR"))
	if editor != "" {
		parts := strings.Fields(editor)
		if len(parts) > 0 {
			args := append(parts[1:], workdir)
			return exec.CommandContext(ctx, parts[0], args...)
		}
	}

	switch runtime.GOOS {
	case "darwin":
		return exec.CommandContext(ctx, "open", workdir)
	case "linux":
		return exec.CommandContext(ctx, "xdg-open", workdir)
	default:
		return exec.CommandContext(ctx, "code", workdir)
	}
}
