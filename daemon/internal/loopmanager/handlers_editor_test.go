package loopmanager

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/algedonia/daemon/internal/repo"
)

func TestResolveEditorCommandPrefersVisualOverEditor(t *testing.T) {
	t.Setenv("VISUAL", "code --reuse-window")
	t.Setenv("EDITOR", "zed")

	assertResolveFromTempDir(t, "code", []string{"--reuse-window"})
}

func TestResolveEditorCommandUsesEditorWhenVisualUnset(t *testing.T) {
	t.Setenv("VISUAL", "")
	t.Setenv("EDITOR", "cursor --new-window")

	assertResolveFromTempDir(t, "cursor", []string{"--new-window"})
}

func TestResolveEditorCommandUsesGitCoreEditor(t *testing.T) {
	t.Setenv("VISUAL", "")
	t.Setenv("EDITOR", "")

	workdir := t.TempDir()

	initCmd := exec.Command("git", "init", "-q")
	initCmd.Dir = workdir
	if out, err := initCmd.CombinedOutput(); err != nil {
		t.Fatalf("git init failed: %v (%s)", err, string(out))
	}

	cfgCmd := exec.Command("git", "config", "core.editor", "subl -n")
	cfgCmd.Dir = workdir
	if out, err := cfgCmd.CombinedOutput(); err != nil {
		t.Fatalf("git config failed: %v (%s)", err, string(out))
	}

	binary, args := resolveEditorCommand(workdir)
	if binary != "subl" {
		t.Fatalf("binary = %q, want %q", binary, "subl")
	}
	if !reflect.DeepEqual(args, []string{"-n"}) {
		t.Fatalf("args = %#v, want %#v", args, []string{"-n"})
	}
}

func TestResolveEditorCommandFallsBackToKnownEditors(t *testing.T) {
	t.Setenv("VISUAL", "")
	t.Setenv("EDITOR", "")

	binDir := t.TempDir()
	makeExecutable(t, binDir, "zed")
	makeExecutable(t, binDir, "subl")
	t.Setenv("PATH", binDir)

	assertResolveFromTempDir(t, "zed", nil)
}

func TestResolveEditorCommandReturnsEmptyWhenNoEditorFound(t *testing.T) {
	t.Setenv("VISUAL", "")
	t.Setenv("EDITOR", "")
	t.Setenv("PATH", t.TempDir())

	binary, args := resolveEditorCommand(t.TempDir())
	if binary != "" {
		t.Fatalf("binary = %q, want empty", binary)
	}
	if len(args) != 0 {
		t.Fatalf("args = %#v, want empty args", args)
	}
}

func assertResolveFromTempDir(t *testing.T, wantBinary string, wantArgs []string) {
	t.Helper()

	binary, args := resolveEditorCommand(t.TempDir())
	if binary != wantBinary {
		t.Fatalf("binary = %q, want %q", binary, wantBinary)
	}
	if !reflect.DeepEqual(args, wantArgs) {
		t.Fatalf("args = %#v, want %#v", args, wantArgs)
	}
}

func makeExecutable(t *testing.T, dir, name string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write executable %s: %v", name, err)
	}
}

func TestResolveOpenEditorTargetWorkspaceRelativePath(t *testing.T) {
	repoRoot := t.TempDir()
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, repoRoot)

	baseDir := t.TempDir()
	mgr.SetWorkspaceBaseDir(baseDir)
	workspaceSlug := "skills-workspace"

	workspaceDir := filepath.Join(baseDir, workspaceSlug)
	if err := os.MkdirAll(filepath.Join(workspaceDir, ".algedonia", "skills", "command"), 0o755); err != nil {
		t.Fatalf("mkdir workspace tree: %v", err)
	}

	target, err := mgr.resolveOpenEditorTarget(
		context.Background(),
		workspaceSlug,
		"",
		filepath.Join(".algedonia", "skills", "command", "SKILL.md"),
	)
	if err != nil {
		t.Fatalf("resolveOpenEditorTarget: %v", err)
	}

	want := filepath.Join(workspaceDir, ".algedonia", "skills", "command", "SKILL.md")
	if target != want {
		t.Fatalf("target = %q, want %q", target, want)
	}
}

func TestResolveOpenEditorTargetRejectsPathEscape(t *testing.T) {
	repoRoot := t.TempDir()
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, repoRoot)

	baseDir := t.TempDir()
	mgr.SetWorkspaceBaseDir(baseDir)

	workspaceSlug := "skills-workspace"
	if err := os.MkdirAll(filepath.Join(baseDir, workspaceSlug), 0o755); err != nil {
		t.Fatalf("mkdir workspace dir: %v", err)
	}

	if _, err := mgr.resolveOpenEditorTarget(
		context.Background(),
		workspaceSlug,
		"",
		filepath.Join("..", "outside.txt"),
	); err == nil {
		t.Fatal("expected path escape error")
	}
}

func TestResolveOpenEditorTargetWithinTicketWorktree(t *testing.T) {
	repoRoot := t.TempDir()
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, repoRoot)

	workspaceSlug := "editor-workspace"
	configureScopedWorktree(t, mgr, workspaceSlug)

	ticketID := "77777777-7777-4777-8777-777777777777"
	target, err := mgr.resolveOpenEditorTarget(
		context.Background(),
		workspaceSlug,
		ticketID,
		"README.md",
	)
	if err != nil {
		t.Fatalf("resolveOpenEditorTarget: %v", err)
	}

	workspaceDir := mgr.workdirForWorkspace(workspaceSlug)
	want := filepath.Join(workspaceDir, "worktrees", repo.TicketPrefix(ticketID), "README.md")
	if target != want {
		t.Fatalf("target = %q, want %q", target, want)
	}
}
