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

	role := payloadStr(payload, "role")
	if role == "" {
		return fmt.Errorf("missing role in start_loop payload")
	}

	agentType := payloadStr(payload, "agent_type")
	if agentType == "" {
		return fmt.Errorf("missing agent_type in start_loop payload")
	}

	task := payloadStr(payload, "task")
	if task == "" {
		return fmt.Errorf("missing task in start_loop payload")
	}

	attempt := parseAttempt(payload["attempt"])
	wsSlug := payloadStr(payload, "workspace_slug")
	ticketID := payloadStr(payload, "ticket_id")

	workdir, workspaceDir, err := m.resolveScopedTicketWorkdir(ctx, wsSlug, ticketID)
	if err != nil {
		return fmt.Errorf("invalid start_loop scope: %w", err)
	}

	return m.StartLoopWithAdapter(ctx, loopID, agentType, role, workdir, workspaceDir, wsSlug,
		ticketID, task, payloadStr(payload, "model"), payloadStr(payload, "effort"), attempt)
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

	expectedWorkdir := filepath.Join(workspaceDir, "worktrees", repo.TicketPrefix(ticketID))
	workdir, err := m.worktreeMgr.EnsureWorktree(ctx, workspaceDir, repo.TicketPrefix(ticketID))
	if err != nil {
		return "", "", fmt.Errorf("ensuring ticket worktree: %w", err)
	}
	if filepath.Clean(workdir) != filepath.Clean(expectedWorkdir) {
		return "", "", fmt.Errorf("failed to resolve ticket worktree at %s", expectedWorkdir)
	}

	return workdir, workspaceDir, nil
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
		return fmt.Errorf("worktree manager not configured")
	}

	workdir := m.workdirForWorkspace(workspaceSlug)
	if workdir == m.repoRoot {
		return fmt.Errorf("workspace base dir not configured for workspace %q", workspaceSlug)
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
	sourcePath := payloadStr(payload, "source_path")

	if workspaceSlug == "" {
		return fmt.Errorf("missing workspace_slug in open_editor payload")
	}
	if ticketID == "" && sourcePath == "" {
		return fmt.Errorf("missing ticket_id or source_path in open_editor payload")
	}

	targetPath, err := m.resolveOpenEditorTarget(ctx, workspaceSlug, ticketID, sourcePath)
	if err != nil {
		return fmt.Errorf("invalid open_editor scope: %w", err)
	}

	cmd := openEditorCommand(ctx, targetPath)
	return cmd.Start()
}

func (m *Manager) resolveOpenEditorTarget(
	ctx context.Context,
	workspaceSlug, ticketID, sourcePath string,
) (string, error) {
	var baseDir string

	if ticketID != "" {
		workdir, _, err := m.resolveScopedTicketWorkdir(ctx, workspaceSlug, ticketID)
		if err != nil {
			return "", err
		}
		baseDir = workdir
	} else {
		baseDir = m.workdirForWorkspace(workspaceSlug)
	}

	baseDir, err := filepath.Abs(baseDir)
	if err != nil {
		return "", fmt.Errorf("resolve base path: %w", err)
	}

	if sourcePath == "" {
		return baseDir, nil
	}

	candidate := sourcePath
	if !filepath.IsAbs(candidate) {
		candidate = filepath.Join(baseDir, candidate)
	}

	targetPath, err := filepath.Abs(candidate)
	if err != nil {
		return "", fmt.Errorf("resolve source path: %w", err)
	}

	rel, err := filepath.Rel(baseDir, targetPath)
	if err != nil {
		return "", fmt.Errorf("relative source path: %w", err)
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("source_path escapes workspace scope")
	}

	return targetPath, nil
}

func openEditorCommand(ctx context.Context, workdir string) *exec.Cmd {
	if binary, args := resolveEditorCommand(workdir); binary != "" {
		return exec.CommandContext(ctx, binary, append(args, workdir)...)
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

func resolveEditorCommand(workdir string) (string, []string) {
	for _, key := range []string{"VISUAL", "EDITOR"} {
		if binary, args := parseEditorSpec(strings.TrimSpace(os.Getenv(key))); binary != "" {
			return binary, args
		}
	}

	if binary, args := parseEditorSpec(gitCoreEditor(workdir)); binary != "" {
		return binary, args
	}

	for _, candidate := range []string{
		"code",
		"cursor",
		"zed",
		"code-insiders",
		"codium",
		"subl",
	} {
		if _, err := exec.LookPath(candidate); err == nil {
			return candidate, nil
		}
	}

	return "", nil
}

func parseEditorSpec(spec string) (string, []string) {
	parts := strings.Fields(spec)
	if len(parts) == 0 {
		return "", nil
	}
	return parts[0], parts[1:]
}

func gitCoreEditor(workdir string) string {
	cmd := exec.Command("git", "config", "--get", "core.editor")
	cmd.Dir = workdir

	out, err := cmd.Output()
	if err != nil {
		return ""
	}

	return strings.TrimSpace(string(out))
}
