package loopmanager

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
)

func TestResolveEditorCommandPrefersVisualOverEditor(t *testing.T) {
	t.Setenv("VISUAL", "code --reuse-window")
	t.Setenv("EDITOR", "zed")

	binary, args := resolveEditorCommand(t.TempDir())
	if binary != "code" {
		t.Fatalf("binary = %q, want %q", binary, "code")
	}
	if !reflect.DeepEqual(args, []string{"--reuse-window"}) {
		t.Fatalf("args = %#v, want %#v", args, []string{"--reuse-window"})
	}
}

func TestResolveEditorCommandUsesEditorWhenVisualUnset(t *testing.T) {
	t.Setenv("VISUAL", "")
	t.Setenv("EDITOR", "cursor --new-window")

	binary, args := resolveEditorCommand(t.TempDir())
	if binary != "cursor" {
		t.Fatalf("binary = %q, want %q", binary, "cursor")
	}
	if !reflect.DeepEqual(args, []string{"--new-window"}) {
		t.Fatalf("args = %#v, want %#v", args, []string{"--new-window"})
	}
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

	binary, args := resolveEditorCommand(t.TempDir())
	if binary != "zed" {
		t.Fatalf("binary = %q, want %q", binary, "zed")
	}
	if len(args) != 0 {
		t.Fatalf("args = %#v, want empty args", args)
	}
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

func makeExecutable(t *testing.T, dir, name string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write executable %s: %v", name, err)
	}
}
