package worktree

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// initBareRepo creates a temporary bare git repo with at least one commit.
func initBareRepo(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	bare := filepath.Join(tmp, "origin.git")

	// Create a normal repo, add a commit, then clone --bare
	work := filepath.Join(tmp, "work")
	for _, args := range [][]string{
		{"init", work},
		{"-C", work, "commit", "--allow-empty", "-m", "init"},
		{"clone", "--bare", work, bare},
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
	return bare
}

func TestEnsureRepo(t *testing.T) {
	originRepo := initBareRepo(t)

	tests := []struct {
		name      string
		setup     func(t *testing.T, baseDir string)
		repoURL   string
		wantErr   bool
		errSubstr string
	}{
		{
			name:    "fresh clone into empty dir",
			repoURL: originRepo,
		},
		{
			name: "existing repo with matching URL fetches",
			setup: func(t *testing.T, baseDir string) {
				t.Helper()
				dest := filepath.Join(baseDir, "ws")
				cmd := exec.Command("git", "clone", "--bare", originRepo, dest)
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("pre-clone: %v\n%s", err, out)
				}
			},
			repoURL: originRepo,
		},
		{
			name: "mismatched URL deletes and re-clones",
			setup: func(t *testing.T, baseDir string) {
				t.Helper()
				dest := filepath.Join(baseDir, "ws")
				// Create a repo with a different origin
				other := initBareRepo(t)
				cmd := exec.Command("git", "clone", "--bare", other, dest)
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("pre-clone: %v\n%s", err, out)
				}
			},
			repoURL: originRepo,
		},
		{
			name:      "bad URL returns error",
			repoURL:   "file:///nonexistent/path/repo.git",
			wantErr:   true,
			errSubstr: "cloning repo",
		},
		{
			name:      "context timeout propagated",
			repoURL:   originRepo,
			wantErr:   true,
			errSubstr: "cloning repo",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			baseDir := t.TempDir()

			if tt.setup != nil {
				tt.setup(t, baseDir)
			}

			cm := NewCloneManager(baseDir, "")

			ctx := context.Background()
			if tt.name == "context timeout propagated" {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, 1*time.Nanosecond)
				defer cancel()
				time.Sleep(2 * time.Millisecond)
			}

			path, err := cm.EnsureRepo(ctx, "ws", tt.repoURL)

			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				if tt.errSubstr != "" && !contains(err.Error(), tt.errSubstr) {
					t.Errorf("error %q should contain %q", err, tt.errSubstr)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			expected := filepath.Join(baseDir, "ws")
			if path != expected {
				t.Errorf("got path %q, want %q", path, expected)
			}

			// Verify it's a valid bare repo
			cmd := exec.Command("git", "-C", path, "rev-parse", "--is-bare-repository")
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("not a git repo: %v\n%s", err, out)
			}
		})
	}
}

func TestCloneManagerInjectableGitPath(t *testing.T) {
	cm := NewCloneManager(t.TempDir(), "/usr/bin/git")
	if cm.GitBin != "/usr/bin/git" {
		t.Errorf("GitBin = %q, want /usr/bin/git", cm.GitBin)
	}
}

func TestCloneManagerDefaultGitPath(t *testing.T) {
	cm := NewCloneManager(t.TempDir(), "")
	if cm.GitBin != "git" {
		t.Errorf("GitBin = %q, want git", cm.GitBin)
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsSubstring(s, substr))
}

func containsSubstring(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
