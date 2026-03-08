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
		if err := ensureSharedSkillLinks(wtPath); err != nil {
			return "", err
		}
		return wtPath, nil
	}

	// If directory exists but is corrupted (no .git file), remove and recreate
	if info, err := os.Stat(wtPath); err == nil && info.IsDir() {
		// Try to remove via git first
		_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "worktree", "remove", "--force", wtPath)
		_ = os.RemoveAll(wtPath)
	}

	// Refresh remote metadata before detecting default branch.
	_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "fetch", "origin")

	// Detect default branch (validates either local or remote refs exist)
	branch, err := wm.defaultBranch(ctx, bareRepo)
	if err != nil {
		return "", fmt.Errorf("detecting default branch: %w", err)
	}
	remoteRef := fmt.Sprintf("refs/remotes/origin/%s", branch)
	remoteRefspec := fmt.Sprintf("refs/heads/%s:%s", branch, remoteRef)
	// Force-update the remote-tracking ref for this branch so new worktrees
	// are based on the latest origin tip even when local bare heads are stale.
	_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "fetch", "origin", remoteRefspec)

	baseRef, err := wm.worktreeBaseRef(ctx, bareRepo, branch)
	if err != nil {
		return "", fmt.Errorf("resolving worktree base ref: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(wtPath), 0o755); err != nil {
		return "", fmt.Errorf("creating worktrees dir: %w", err)
	}

	// Prune stale worktree entries before adding
	_, _, _ = runGitCmd(ctx, wm.GitBin, bareRepo, "worktree", "prune")

	_, _, err = runGitCmd(ctx, wm.GitBin, bareRepo, "worktree", "add", "--detach", wtPath, baseRef)
	if err != nil {
		return "", fmt.Errorf("creating worktree: %w", err)
	}

	if err := ensureSharedSkillLinks(wtPath); err != nil {
		return "", err
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

	// Verify the branch ref actually exists either locally or in origin.
	if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", "refs/remotes/origin/"+branch); err == nil {
		return branch, nil
	}
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
					if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", "refs/remotes/origin/"+remote); err == nil {
						return remote, nil
					}
					if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", "refs/heads/"+remote); err == nil {
						return remote, nil
					}
				}
			}
		}
	}

	// Last resort: try common defaults.
	for _, fallback := range []string{"main", "master"} {
		if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", "refs/remotes/origin/"+fallback); err == nil {
			return fallback, nil
		}
		if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", "refs/heads/"+fallback); err == nil {
			return fallback, nil
		}
	}

	return "", fmt.Errorf("no valid default branch found in %s", bareRepo)
}

// worktreeBaseRef chooses the git ref used to seed a new worktree.
// Prefer the fetched remote-tracking branch so worktrees start from the latest origin tip.
func (wm *GitWorktreeManager) worktreeBaseRef(ctx context.Context, bareRepo, branch string) (string, error) {
	remoteRef := "refs/remotes/origin/" + branch
	if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", remoteRef); err == nil {
		return remoteRef, nil
	}

	localRef := "refs/heads/" + branch
	if _, _, err := runGitCmd(ctx, wm.GitBin, bareRepo, "rev-parse", "--verify", localRef); err == nil {
		return localRef, nil
	}

	return "", fmt.Errorf("missing both %s and %s", remoteRef, localRef)
}

// TicketPrefix returns the first 8 hex characters of a UUID (hyphens stripped).
func TicketPrefix(ticketID string) string {
	clean := strings.ReplaceAll(ticketID, "-", "")
	if len(clean) > 8 {
		return clean[:8]
	}
	return clean
}

func ensureSharedSkillLinks(worktreePath string) error {
	algedoniaSkills := filepath.Join(worktreePath, ".algedonia", "skills")
	if err := os.MkdirAll(algedoniaSkills, 0o755); err != nil {
		return fmt.Errorf("creating .algedonia/skills: %w", err)
	}

	if err := ensureRelativeSkillLink(worktreePath, ".codex", "../.algedonia/skills"); err != nil {
		return err
	}

	if err := ensureRelativeSkillLink(worktreePath, ".claude", "../.algedonia/skills"); err != nil {
		return err
	}

	return nil
}

func ensureRelativeSkillLink(worktreePath, toolDir, target string) error {
	linkDir := filepath.Join(worktreePath, toolDir)
	if err := os.MkdirAll(linkDir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", toolDir, err)
	}

	linkPath := filepath.Join(linkDir, "skills")
	info, err := os.Lstat(linkPath)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			currentTarget, readErr := os.Readlink(linkPath)
			if readErr == nil && currentTarget == target {
				return nil
			}

			if rmErr := os.Remove(linkPath); rmErr != nil {
				return fmt.Errorf("replacing %s symlink: %w", linkPath, rmErr)
			}
		} else {
			// Preserve existing non-symlink skills directories.
			return nil
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("checking %s: %w", linkPath, err)
	}

	if err := os.Symlink(target, linkPath); err != nil {
		return fmt.Errorf("creating %s symlink: %w", linkPath, err)
	}

	return nil
}
