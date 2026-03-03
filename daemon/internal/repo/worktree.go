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

	// Detect default branch
	branch, err := wm.defaultBranch(ctx, bareRepo)
	if err != nil {
		return "", fmt.Errorf("detecting default branch: %w", err)
	}

	// Fetch latest from origin so worktree starts from up-to-date main.
	// In bare repos, the default refspec maps remote heads to local heads directly,
	// so after fetch, `branch` points to the latest remote commit.
	_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "fetch", "origin")

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

// defaultBranch returns the default branch name for a bare repo via symbolic-ref.
func (wm *GitWorktreeManager) defaultBranch(ctx context.Context, bareRepo string) (string, error) {
	stdout, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "symbolic-ref", "HEAD")
	if err != nil {
		return "", err
	}
	ref := strings.TrimSpace(stdout)
	// refs/heads/main -> main
	return strings.TrimPrefix(ref, "refs/heads/"), nil
}

// TicketPrefix returns the first 8 hex characters of a UUID (hyphens stripped).
func TicketPrefix(ticketID string) string {
	clean := strings.ReplaceAll(ticketID, "-", "")
	if len(clean) > 8 {
		return clean[:8]
	}
	return clean
}
