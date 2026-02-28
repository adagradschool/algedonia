// Package repo manages git bare-repo clone and fetch operations.
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

// RepoManager abstracts bare-repo clone and fetch operations.
type RepoManager interface {
	// EnsureRepo clones or fetches a bare repo for the given workspace.
	// Returns the path to the bare repo directory.
	EnsureRepo(ctx context.Context, workspaceSlug, repoURL string) (string, error)
}

// CloneManager implements RepoManager using the git CLI.
type CloneManager struct {
	// BaseDir is the parent directory for workspace bare repos.
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
// If the directory exists with a matching origin URL, it fetches.
// If the origin URL differs, it deletes and re-clones.
// If the directory does not exist, it clones fresh.
func (cm *CloneManager) EnsureRepo(ctx context.Context, workspaceSlug, repoURL string) (string, error) {
	baseDir, err := cm.resolveBaseDir()
	if err != nil {
		return "", fmt.Errorf("resolving base dir: %w", err)
	}

	repoPath := filepath.Join(baseDir, workspaceSlug)

	info, err := os.Stat(repoPath)
	if err == nil && info.IsDir() {
		return cm.handleExistingRepo(ctx, repoPath, repoURL)
	}

	return cm.cloneBare(ctx, repoPath, repoURL)
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

	if strings.TrimSpace(currentURL) == strings.TrimSpace(repoURL) {
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
	if err != nil {
		return "", fmt.Errorf("fetching repo: %w", err)
	}
	return repoPath, nil
}

func (cm *CloneManager) cloneBare(ctx context.Context, repoPath, repoURL string) (string, error) {
	if err := os.MkdirAll(filepath.Dir(repoPath), 0o755); err != nil {
		return "", fmt.Errorf("creating parent dir: %w", err)
	}

	_, _, err := cm.runGit(ctx, "", "clone", "--bare", repoURL, repoPath)
	if err != nil {
		return "", fmt.Errorf("cloning repo: %w", err)
	}
	return repoPath, nil
}

func (cm *CloneManager) runGit(ctx context.Context, dir string, args ...string) (string, string, error) {
	gitCtx, cancel := context.WithTimeout(ctx, GitTimeout)
	defer cancel()

	cmd := exec.CommandContext(gitCtx, cm.GitBin, args...)
	if dir != "" {
		cmd.Dir = dir
	}

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
