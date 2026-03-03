// Package repo manages git clone and fetch operations for workspace repos.
package repo

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// GitTimeout is the default timeout for git commands.
const GitTimeout = 120 * time.Second

// RepoManager abstracts clone and fetch operations.
type RepoManager interface {
	// EnsureRepo clones or fetches a repo for the given workspace.
	// Returns the path to the repo directory.
	EnsureRepo(ctx context.Context, workspaceSlug, repoURL string) (string, error)
}

// CloneManager implements RepoManager using the git CLI.
type CloneManager struct {
	// BaseDir is the parent directory for workspace repos.
	// Defaults to ~/.algedonia/workspaces if empty.
	BaseDir string

	// GitBin is the path to the git binary. Defaults to "git".
	GitBin string
}

// NewCloneManager creates a CloneManager with the given base directory and git binary path.
func NewCloneManager(baseDir, gitBin string) *CloneManager {
	if gitBin == "" {
		gitBin = "git"
	}
	return &CloneManager{BaseDir: baseDir, GitBin: gitBin}
}

// EnsureRepo clones or fetches a bare repository for the workspace.
// The bare repo lives at <baseDir>/<slug>/root so that worktrees can
// be placed alongside it at <baseDir>/<slug>/worktrees/<prefix>.
// Returns the workspace directory (<baseDir>/<slug>), not the bare repo path.
func (cm *CloneManager) EnsureRepo(ctx context.Context, workspaceSlug, repoURL string) (string, error) {
	baseDir, err := cm.resolveBaseDir()
	if err != nil {
		return "", fmt.Errorf("resolving base dir: %w", err)
	}

	workspaceDir := filepath.Join(baseDir, workspaceSlug)
	repoPath := filepath.Join(workspaceDir, "root")

	info, err := os.Stat(repoPath)
	if err == nil && info.IsDir() {
		if _, err := cm.handleExistingRepo(ctx, repoPath, repoURL); err != nil {
			return "", err
		}
		return workspaceDir, nil
	}

	if _, err := cm.cloneBare(ctx, repoPath, repoURL); err != nil {
		return "", err
	}
	return workspaceDir, nil
}

func (cm *CloneManager) resolveBaseDir() (string, error) {
	if cm.BaseDir != "" {
		return cm.BaseDir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("getting home dir: %w", err)
	}
	return filepath.Join(home, ".algedonia", "workspaces"), nil
}

func (cm *CloneManager) handleExistingRepo(ctx context.Context, repoPath, repoURL string) (string, error) {
	currentURL, err := cm.getOriginURL(ctx, repoPath)
	if err != nil {
		return "", fmt.Errorf("reading origin URL: %w", err)
	}

	if urlsEquivalent(currentURL, repoURL) {
		return cm.fetchAll(ctx, repoPath)
	}

	if err := os.RemoveAll(repoPath); err != nil {
		return "", fmt.Errorf("removing mismatched repo: %w", err)
	}

	return cm.cloneBare(ctx, repoPath, repoURL)
}

func (cm *CloneManager) getOriginURL(ctx context.Context, repoPath string) (string, error) {
	stdout, _, err := cm.runGit(ctx, repoPath, "remote", "get-url", "origin")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(stdout), nil
}

func (cm *CloneManager) fetchAll(ctx context.Context, repoPath string) (string, error) {
	_, _, err := cm.runGit(ctx, repoPath, "fetch", "--all")
	if err == nil {
		return repoPath, nil
	}

	currentURL, urlErr := cm.getOriginURL(ctx, repoPath)
	if urlErr != nil {
		return "", fmt.Errorf("fetching repo: %w", err)
	}

	alt, ok := alternateURL(currentURL)
	if !ok {
		return "", fmt.Errorf("fetching repo: %w", err)
	}

	// Switch origin to alternate URL and retry.
	if _, _, setErr := cm.runGit(ctx, repoPath, "remote", "set-url", "origin", alt); setErr != nil {
		return "", fmt.Errorf("fetching repo: %w", err)
	}

	_, _, retryErr := cm.runGit(ctx, repoPath, "fetch", "--all")
	if retryErr != nil {
		// Revert origin URL.
		_, _, _ = cm.runGit(ctx, repoPath, "remote", "set-url", "origin", currentURL)
		return "", fmt.Errorf("fetching repo (tried %s and %s): %w", currentURL, alt, err)
	}
	return repoPath, nil
}

func (cm *CloneManager) cloneBare(ctx context.Context, repoPath, repoURL string) (string, error) {
	if err := os.MkdirAll(filepath.Dir(repoPath), 0o755); err != nil {
		return "", fmt.Errorf("creating parent dir: %w", err)
	}

	_, _, err := cm.runGit(ctx, "", "clone", "--bare", repoURL, repoPath)
	if err == nil {
		return repoPath, nil
	}

	alt, ok := alternateURL(repoURL)
	if !ok {
		return "", fmt.Errorf("cloning repo: %w", err)
	}

	// Clean up partial clone before retry.
	_ = os.RemoveAll(repoPath)

	_, _, altErr := cm.runGit(ctx, "", "clone", "--bare", alt, repoPath)
	if altErr != nil {
		return "", fmt.Errorf("cloning repo (tried %s and %s): %w", repoURL, alt, err)
	}
	return repoPath, nil
}

// runGitCmd executes a git command with a timeout. Shared by CloneManager and WorktreeManager.
func runGitCmd(ctx context.Context, gitBin, dir string, args ...string) (string, string, error) {
	gitCtx, cancel := context.WithTimeout(ctx, GitTimeout)
	defer cancel()

	cmd := exec.CommandContext(gitCtx, gitBin, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		return stdout.String(), stderr.String(),
			fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), stderr.String(), nil
}

func (cm *CloneManager) runGit(ctx context.Context, dir string, args ...string) (string, string, error) {
	return runGitCmd(ctx, cm.GitBin, dir, args...)
}
