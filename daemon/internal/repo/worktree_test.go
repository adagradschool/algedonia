package repo

import (
	"context"
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
				_, err := wm.EnsureWorktree(context.Background(), wsDir, "reuse123")
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
			path, err := wm.EnsureWorktree(context.Background(), wsDir, tt.ticketPrefix)

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
	path, err := wm.EnsureWorktree(context.Background(), wsDir, "remove01")
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
	path, err := wm.EnsureWorktree(context.Background(), wsDir, "mismatch1")
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
	path1, err := wm.EnsureWorktree(context.Background(), wsDir, "idem1234")
	if err != nil {
		t.Fatalf("first create: %v", err)
	}

	// Write a file to verify it's preserved on second call
	testFile := filepath.Join(path1, "test.txt")
	if err := os.WriteFile(testFile, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	path2, err := wm.EnsureWorktree(context.Background(), wsDir, "idem1234")
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
