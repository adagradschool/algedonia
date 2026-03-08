package loopmanager

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

const checkerSnapshotCommitMessageTemplate = "algedonia checker snapshot loop=%s attempt=%d"

func checkerSnapshotCommitMessage(loopID string, attempt int) string {
	return fmt.Sprintf(checkerSnapshotCommitMessageTemplate, loopID, attempt)
}

func snapshotCheckerCompletion(ctx context.Context, workdir, loopID string, attempt int) (string, bool, error) {
	workdir = strings.TrimSpace(workdir)
	if workdir == "" {
		return "", false, fmt.Errorf("workdir is required for checker snapshot commit")
	}

	dirty, err := worktreeHasChanges(ctx, workdir)
	if err != nil {
		return "", false, fmt.Errorf("checking worktree changes: %w", err)
	}
	if !dirty {
		return "", false, nil
	}

	if _, err := runGitOutput(ctx, workdir, false, "add", "-A"); err != nil {
		return "", false, fmt.Errorf("git add -A: %w", err)
	}

	dirty, err = worktreeHasChanges(ctx, workdir)
	if err != nil {
		return "", false, fmt.Errorf("checking staged changes: %w", err)
	}
	if !dirty {
		return "", false, nil
	}

	commitMsg := checkerSnapshotCommitMessage(loopID, attempt)
	if _, err := runGitCombined(ctx, workdir, "commit", "-m", commitMsg); err != nil {
		return "", false, fmt.Errorf("git commit snapshot: %w", err)
	}

	head, err := runGitOutput(ctx, workdir, false, "rev-parse", "HEAD")
	if err != nil {
		return "", false, fmt.Errorf("git rev-parse HEAD: %w", err)
	}
	sha := strings.TrimSpace(string(head))
	if sha == "" {
		return "", false, fmt.Errorf("git rev-parse HEAD returned empty output")
	}
	return sha, true, nil
}

func worktreeHasChanges(ctx context.Context, workdir string) (bool, error) {
	status, err := runGitOutput(ctx, workdir, false, "status", "--porcelain")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(status)) != "", nil
}

func runGitCombined(ctx context.Context, workdir string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = workdir
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg != "" {
			return nil, fmt.Errorf("%w: %s", err, msg)
		}
		return nil, err
	}
	return out, nil
}
