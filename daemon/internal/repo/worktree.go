package repo

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// WorktreeManager abstracts git worktree operations.
type WorktreeManager interface {
	// EnsureWorktree creates or reuses a worktree at workspaceDir/worktrees/ticketPrefix.
	// The bare repo is expected at workspaceDir/root.
	EnsureWorktree(ctx context.Context, workspaceDir, ticketPrefix string) (string, error)

	// RemoveWorktree removes a worktree for the given ticket prefix.
	RemoveWorktree(ctx context.Context, workspaceDir, ticketPrefix string) error
}

// GitWorktreeManager implements WorktreeManager using the git CLI.
type GitWorktreeManager struct {
	GitBin string
}

// NewWorktreeManager creates a GitWorktreeManager with the given git binary path.
func NewWorktreeManager(gitBin string) *GitWorktreeManager {
	if gitBin == "" {
		gitBin = "git"
	}
	return &GitWorktreeManager{GitBin: gitBin}
}

// EnsureWorktree creates a worktree at workspaceDir/worktrees/ticketPrefix
// from the bare repo at workspaceDir/root. Returns the worktree path.
// If the worktree already exists and is valid, it returns the existing path.
func (wm *GitWorktreeManager) EnsureWorktree(ctx context.Context, workspaceDir, ticketPrefix string) (string, error) {
	bareRepo := filepath.Join(workspaceDir, "root")
	wtPath := filepath.Join(workspaceDir, "worktrees", ticketPrefix)

	// Check if worktree already exists and is valid
	if info, err := os.Stat(filepath.Join(wtPath, ".git")); err == nil && !info.IsDir() {
		return wtPath, nil
	}

	// If directory exists but is corrupted (no .git file), remove and recreate
	if info, err := os.Stat(wtPath); err == nil && info.IsDir() {
		// Try to remove via git first
		_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "worktree", "remove", "--force", wtPath)
		_ = os.RemoveAll(wtPath)
	}

	// Fetch latest from origin before detecting default branch, so that
	// local refs are up-to-date and we can validate the branch exists.
	_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "fetch", "origin")

	// Detect default branch (validates ref exists after fetch)
	branch, err := wm.defaultBranch(ctx, bareRepo)
	if err != nil {
		return "", fmt.Errorf("detecting default branch: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(wtPath), 0o755); err != nil {
		return "", fmt.Errorf("creating worktrees dir: %w", err)
	}

	// Prune stale worktree entries before adding
	_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "worktree", "prune")

	_, _, err = runGitCmd(ctx, wm.GitBin, bareRepo, "worktree", "add", "--detach", wtPath, branch)
	if err != nil {
		return "", fmt.Errorf("creating worktree: %w", err)
	}

	return wtPath, nil
}

// RemoveWorktree removes a worktree for the given ticket prefix.
func (wm *GitWorktreeManager) RemoveWorktree(ctx context.Context, workspaceDir, ticketPrefix string) error {
	bareRepo := filepath.Join(workspaceDir, "root")
	wtPath := filepath.Join(workspaceDir, "worktrees", ticketPrefix)

	if _, err := os.Stat(wtPath); os.IsNotExist(err) {
		return nil
	}

	_, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "worktree", "remove", "--force", wtPath)
	if err != nil {
		// Fallback: manual removal + prune
		if rmErr := os.RemoveAll(wtPath); rmErr != nil {
			return fmt.Errorf("removing worktree dir: %w", rmErr)
		}
		_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "worktree", "prune")
	}

	return nil
}

// defaultBranch returns the default branch name for a bare repo.
// It reads HEAD's symbolic-ref and verifies the ref exists. If the ref
// doesn't exist (e.g. HEAD points to "main" but the remote uses "master"),
// it falls back to querying the remote's HEAD, then tries common defaults.
func (wm *GitWorktreeManager) defaultBranch(ctx context.Context, bareRepo string) (string, error) {
	stdout, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "symbolic-ref", "HEAD")
	if err != nil {
		return "", err
	}
	branch := strings.TrimPrefix(strings.TrimSpace(stdout), "refs/heads/")

	// Verify the branch ref actually exists (it may not if HEAD was set by
	// init.defaultBranch but the remote uses a different default).
	if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", "refs/heads/"+branch); err == nil {
		return branch, nil
	}

	// Branch from symbolic-ref doesn't exist; detect from remote HEAD.
	if out, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "ls-remote", "--symref", "origin", "HEAD"); err == nil {
		// Output: "ref: refs/heads/master\tHEAD\n<sha>\tHEAD\n"
		for _, line := range strings.Split(out, "\n") {
			if strings.HasPrefix(line, "ref:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					remote := strings.TrimPrefix(fields[1], "refs/heads/")
					if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", "refs/heads/"+remote); err == nil {
						return remote, nil
					}
				}
			}
		}
	}

	// Last resort: try common defaults.
	for _, fallback := range []string{"main", "master"} {
		if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", "refs/heads/"+fallback); err == nil {
			return fallback, nil
		}
	}

	return "", fmt.Errorf("no valid default branch found in %s", bareRepo)
}

// TicketPrefix returns the first 8 hex characters of a UUID (hyphens stripped).
func TicketPrefix(ticketID string) string {
	clean := strings.ReplaceAll(ticketID, "-", "")
	if len(clean) > 8 {
		return clean[:8]
	}
	return clean
}
