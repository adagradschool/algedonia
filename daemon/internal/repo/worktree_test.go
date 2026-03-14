package repo

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// setupBareInWorkspaceDir creates a bare repo at workspaceDir/root with one commit.
func setupBareInWorkspaceDir(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	workspaceDir := filepath.Join(tmp, "my-ws")
	bareRepo := filepath.Join(workspaceDir, "root")

	work := filepath.Join(tmp, "work")
	for _, args := range [][]string{
		{"init", work},
		{"-C", work, "commit", "--allow-empty", "-m", "init"},
		{"clone", "--bare", work, bareRepo},
	} {
		cmd := exec.Command("git", args...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=test", "GIT_AUTHOR_EMAIL=test@test.com",
			"GIT_COMMITTER_NAME=test", "GIT_COMMITTER_EMAIL=test@test.com",
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	return workspaceDir
}

func TestEnsureWorktree(t *testing.T) {
	tests := []struct {
		name         string
		setup        func(t *testing.T, wsDir string)
		ticketPrefix string
		wantErr      bool
	}{
		{
			name:         "create new worktree",
			ticketPrefix: "abcd1234",
		},
		{
			name:         "reuse existing worktree",
			ticketPrefix: "reuse123",
			setup: func(t *testing.T, wsDir string) {
				t.Helper()
				wm := NewWorktreeManager("")
				_, err := wm.EnsureWorktree(context.Background(), wsDir, WorktreeSpec{TicketPrefix: "reuse123"})
				if err != nil {
					t.Fatalf("pre-create worktree: %v", err)
				}
			},
		},
		{
			name:         "recreate corrupted worktree",
			ticketPrefix: "corrupt1",
			setup: func(t *testing.T, wsDir string) {
				t.Helper()
				// Create the directory but without .git file (corrupted)
				wtPath := filepath.Join(wsDir, "worktrees", "corrupt1")
				if err := os.MkdirAll(wtPath, 0o755); err != nil {
					t.Fatal(err)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			wsDir := setupBareInWorkspaceDir(t)

			if tt.setup != nil {
				tt.setup(t, wsDir)
			}

			wm := NewWorktreeManager("")
			path, err := wm.EnsureWorktree(context.Background(), wsDir, WorktreeSpec{TicketPrefix: tt.ticketPrefix})

			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			expected := filepath.Join(wsDir, "worktrees", tt.ticketPrefix)
			if path != expected {
				t.Errorf("got path %q, want %q", path, expected)
			}

			// Verify .git file exists (worktree marker)
			gitFile := filepath.Join(path, ".git")
			info, err := os.Stat(gitFile)
			if err != nil {
				t.Fatalf(".git file missing: %v", err)
			}
			if info.IsDir() {
				t.Fatal(".git should be a file (worktree link), not a directory")
			}

			assertSharedSkillLinks(t, path)
		})
	}
}

func TestRemoveWorktree(t *testing.T) {
	wsDir := setupBareInWorkspaceDir(t)
	wm := NewWorktreeManager("")

	// Create a worktree first
	path, err := wm.EnsureWorktree(context.Background(), wsDir, WorktreeSpec{TicketPrefix: "remove01"})
	if err != nil {
		t.Fatalf("creating worktree: %v", err)
	}

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("worktree dir should exist: %v", err)
	}

	// Remove it
	err = wm.RemoveWorktree(context.Background(), wsDir, "remove01")
	if err != nil {
		t.Fatalf("removing worktree: %v", err)
	}

	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("worktree dir should be gone after removal")
	}

	// Removing non-existent worktree should be a no-op
	err = wm.RemoveWorktree(context.Background(), wsDir, "nonexistent")
	if err != nil {
		t.Fatalf("removing non-existent worktree should not error: %v", err)
	}
}

func TestDefaultBranchDetection(t *testing.T) {
	wsDir := setupBareInWorkspaceDir(t)
	wm := NewWorktreeManager("")

	// The default branch from our test setup should be "master" or "main"
	bareRepo := filepath.Join(wsDir, "root")
	branch, err := wm.defaultBranch(context.Background(), bareRepo)
	if err != nil {
		t.Fatalf("detecting default branch: %v", err)
	}
	if branch != "main" && branch != "master" {
		t.Errorf("expected main or master, got %q", branch)
	}
}

func TestDefaultBranchFallbackOnMismatch(t *testing.T) {
	wsDir := setupBareInWorkspaceDir(t)
	bareRepo := filepath.Join(wsDir, "root")

	// Detect what the actual branch is, then point HEAD to a non-existent ref.
	wm := NewWorktreeManager("")
	actualBranch, err := wm.defaultBranch(context.Background(), bareRepo)
	if err != nil {
		t.Fatalf("detecting actual branch: %v", err)
	}

	// Point HEAD to a branch that doesn't exist (simulates init.defaultBranch mismatch)
	fakeBranch := "nonexistent-branch"
	cmd := exec.Command("git", "-C", bareRepo, "symbolic-ref", "HEAD", "refs/heads/"+fakeBranch)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("setting symbolic-ref: %v\n%s", err, out)
	}

	// defaultBranch should fall back to the actual branch
	got, err := wm.defaultBranch(context.Background(), bareRepo)
	if err != nil {
		t.Fatalf("defaultBranch with mismatched HEAD: %v", err)
	}
	if got != actualBranch {
		t.Errorf("expected fallback to %q, got %q", actualBranch, got)
	}
}

func TestEnsureWorktreeMismatchedHEAD(t *testing.T) {
	wsDir := setupBareInWorkspaceDir(t)
	bareRepo := filepath.Join(wsDir, "root")

	// Point HEAD to "main" but the actual branch is "master" (or vice versa)
	cmd := exec.Command("git", "-C", bareRepo, "symbolic-ref", "HEAD", "refs/heads/doesnotexist")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("setting symbolic-ref: %v\n%s", err, out)
	}

	wm := NewWorktreeManager("")
	path, err := wm.EnsureWorktree(context.Background(), wsDir, WorktreeSpec{TicketPrefix: "mismatch1"})
	if err != nil {
		t.Fatalf("EnsureWorktree with mismatched HEAD should succeed: %v", err)
	}

	// Verify worktree was created
	gitFile := filepath.Join(path, ".git")
	if _, err := os.Stat(gitFile); err != nil {
		t.Fatalf(".git file missing: %v", err)
	}

	assertSharedSkillLinks(t, path)
}

func TestTicketPrefix(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"abcdef12-3456-7890-abcd-ef1234567890", "abcdef12"},
		{"short", "short"},
		{"12345678", "12345678"},
		{"", ""},
	}
	for _, tt := range tests {
		got := TicketPrefix(tt.input)
		if got != tt.want {
			t.Errorf("TicketPrefix(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestEnsureWorktreeIdempotent(t *testing.T) {
	wsDir := setupBareInWorkspaceDir(t)
	wm := NewWorktreeManager("")

	// Create twice — should return same path without error
	path1, err := wm.EnsureWorktree(context.Background(), wsDir, WorktreeSpec{TicketPrefix: "idem1234"})
	if err != nil {
		t.Fatalf("first create: %v", err)
	}

	// Write a file to verify it's preserved on second call
	testFile := filepath.Join(path1, "test.txt")
	if err := os.WriteFile(testFile, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	path2, err := wm.EnsureWorktree(context.Background(), wsDir, WorktreeSpec{TicketPrefix: "idem1234"})
	if err != nil {
		t.Fatalf("second create: %v", err)
	}

	if path1 != path2 {
		t.Errorf("paths differ: %q vs %q", path1, path2)
	}

	// File should still be there
	if _, err := os.Stat(testFile); err != nil {
		t.Error("test file should be preserved on idempotent call")
	}

	assertSharedSkillLinks(t, path2)
}

func TestEnsureWorktreeUsesLatestOriginDefaultBranch(t *testing.T) {
	wsDir := setupBareInWorkspaceDir(t)
	bareRepo := filepath.Join(wsDir, "root")
	wm := NewWorktreeManager("")

	branch, err := wm.defaultBranch(context.Background(), bareRepo)
	if err != nil {
		t.Fatalf("detecting default branch: %v", err)
	}

	originURLCmd := exec.Command("git", "-C", bareRepo, "remote", "get-url", "origin")
	originURLOut, err := originURLCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("getting origin URL: %v\n%s", err, originURLOut)
	}
	originWorktree := strings.TrimSpace(string(originURLOut))

	commitCmd := exec.Command("git", "-C", originWorktree, "commit", "--allow-empty", "-m", "advance origin")
	commitCmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=test", "GIT_AUTHOR_EMAIL=test@test.com",
		"GIT_COMMITTER_NAME=test", "GIT_COMMITTER_EMAIL=test@test.com",
	)
	if out, err := commitCmd.CombinedOutput(); err != nil {
		t.Fatalf("committing in origin worktree: %v\n%s", err, out)
	}

	path, err := wm.EnsureWorktree(
		context.Background(),
		wsDir,
		WorktreeSpec{TicketPrefix: "latest01", TicketType: "feature", TicketCode: "ALG-108"},
	)
	if err != nil {
		t.Fatalf("EnsureWorktree: %v", err)
	}

	worktreeHead, err := revParse(t, path, "HEAD")
	if err != nil {
		t.Fatalf("reading worktree HEAD: %v", err)
	}

	localRef := fmt.Sprintf("refs/heads/%s", branch)
	localHead, err := revParse(t, bareRepo, localRef)
	if err != nil {
		t.Fatalf("reading local bare ref: %v", err)
	}

	remoteRef := fmt.Sprintf("refs/remotes/origin/%s", branch)
	remoteHead, err := revParse(t, bareRepo, remoteRef)
	if err != nil {
		t.Fatalf("reading remote tracking ref: %v", err)
	}

	if localHead == remoteHead {
		t.Fatalf("test precondition failed: expected stale local ref, got equal SHAs %s", localHead)
	}
	if worktreeHead != remoteHead {
		t.Fatalf("worktree HEAD = %s, want latest %s from %s", worktreeHead, remoteHead, remoteRef)
	}

	branchName, err := currentBranch(t, path)
	if err != nil {
		t.Fatalf("reading current branch: %v", err)
	}
	if branchName != "feature/ALG-108" {
		t.Fatalf("branch = %s, want feature/ALG-108", branchName)
	}
}

func TestEnsureWorktreeFailsOnLocalBranchCollision(t *testing.T) {
	wsDir := setupBareInWorkspaceDir(t)
	bareRepo := filepath.Join(wsDir, "root")
	wm := NewWorktreeManager("")

	branchName, err := TicketBranchName("feature", "ALG-108")
	if err != nil {
		t.Fatalf("TicketBranchName: %v", err)
	}

	branch, err := wm.defaultBranch(context.Background(), bareRepo)
	if err != nil {
		t.Fatalf("detecting default branch: %v", err)
	}
	baseRef, err := wm.worktreeBaseRef(context.Background(), bareRepo, branch)
	if err != nil {
		t.Fatalf("worktreeBaseRef: %v", err)
	}

	if _, _, err := runGitCmd(context.Background(), "git", bareRepo, "branch", branchName, baseRef); err != nil {
		t.Fatalf("creating local colliding branch: %v", err)
	}

	_, err = wm.EnsureWorktree(
		context.Background(),
		wsDir,
		WorktreeSpec{TicketPrefix: "localdup", TicketType: "feature", TicketCode: "ALG-108"},
	)
	if err == nil {
		t.Fatal("expected collision error, got nil")
	}
	if !strings.Contains(err.Error(), "branch name collision") || !strings.Contains(err.Error(), "local") {
		t.Fatalf("error = %v, want local branch collision", err)
	}
}

func TestEnsureWorktreeFailsOnOriginBranchCollision(t *testing.T) {
	wsDir := setupBareInWorkspaceDir(t)
	bareRepo := filepath.Join(wsDir, "root")
	wm := NewWorktreeManager("")

	branchName, err := TicketBranchName("feature", "ALG-108")
	if err != nil {
		t.Fatalf("TicketBranchName: %v", err)
	}

	branch, err := wm.defaultBranch(context.Background(), bareRepo)
	if err != nil {
		t.Fatalf("detecting default branch: %v", err)
	}
	baseRef, err := wm.worktreeBaseRef(context.Background(), bareRepo, branch)
	if err != nil {
		t.Fatalf("worktreeBaseRef: %v", err)
	}
	baseSHA, err := revParse(t, bareRepo, baseRef)
	if err != nil {
		t.Fatalf("revParse base ref: %v", err)
	}
	remoteRef := "refs/remotes/origin/" + branchName
	if _, _, err := runGitCmd(context.Background(), "git", bareRepo, "update-ref", remoteRef, baseSHA); err != nil {
		t.Fatalf("creating origin colliding ref: %v", err)
	}

	_, err = wm.EnsureWorktree(
		context.Background(),
		wsDir,
		WorktreeSpec{TicketPrefix: "origindup", TicketType: "feature", TicketCode: "ALG-108"},
	)
	if err == nil {
		t.Fatal("expected collision error, got nil")
	}
	if !strings.Contains(err.Error(), "branch name collision") || !strings.Contains(err.Error(), "origin") {
		t.Fatalf("error = %v, want origin branch collision", err)
	}
}

func TestEnsureRepoReturnsWorkspaceDir(t *testing.T) {
	originRepo := initBareRepo(t)
	baseDir := t.TempDir()
	cm := NewCloneManager(baseDir, "")

	path, err := cm.EnsureRepo(context.Background(), "test-ws", originRepo)
	if err != nil {
		t.Fatalf("EnsureRepo: %v", err)
	}

	expected := filepath.Join(baseDir, "test-ws")
	if path != expected {
		t.Errorf("got path %q, want %q", path, expected)
	}

	// Verify bare repo is at path/root
	rootPath := filepath.Join(path, "root")
	cmd := exec.Command("git", "-C", rootPath, "rev-parse", "--is-bare-repository")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("not a bare repo at root: %v\n%s", err, out)
	}
	if strings.TrimSpace(string(out)) != "true" {
		t.Error("root should be a bare repository")
	}
}

func assertSharedSkillLinks(t *testing.T, worktreePath string) {
	t.Helper()

	if info, err := os.Stat(filepath.Join(worktreePath, ".algedonia", "skills")); err != nil {
		t.Fatalf("missing .algedonia/skills: %v", err)
	} else if !info.IsDir() {
		t.Fatal(".algedonia/skills should be a directory")
	}

	assertSkillLink := func(path string) {
		t.Helper()

		info, err := os.Lstat(path)
		if err != nil {
			t.Fatalf("missing skill link %s: %v", path, err)
		}
		if info.Mode()&os.ModeSymlink == 0 {
			t.Fatalf("%s should be a symlink", path)
		}
		target, err := os.Readlink(path)
		if err != nil {
			t.Fatalf("reading symlink %s: %v", path, err)
		}
		if target != "../.algedonia/skills" {
			t.Fatalf("%s target = %q, want %q", path, target, "../.algedonia/skills")
		}
	}

	assertSkillLink(filepath.Join(worktreePath, ".codex", "skills"))
	assertSkillLink(filepath.Join(worktreePath, ".claude", "skills"))
}

func revParse(t *testing.T, repoPath, ref string) (string, error) {
	t.Helper()

	cmd := exec.Command("git", "-C", repoPath, "rev-parse", "--verify", ref)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git rev-parse %s: %v: %s", ref, err, out)
	}
	return strings.TrimSpace(string(out)), nil
}

func currentBranch(t *testing.T, repoPath string) (string, error) {
	t.Helper()

	cmd := exec.Command("git", "-C", repoPath, "branch", "--show-current")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git branch --show-current: %v: %s", err, out)
	}
	return strings.TrimSpace(string(out)), nil
}
