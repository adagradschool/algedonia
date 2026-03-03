package runtimepath

import (
	"path/filepath"
	"testing"
)

func TestWorkspaceRuntimeDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	got, err := WorkspaceRuntimeDir("scope")
	if err != nil {
		t.Fatalf("WorkspaceRuntimeDir returned error: %v", err)
	}

	want := filepath.Join(home, ".algedonia", "workspaces", "scope", "runtime")
	if got != want {
		t.Fatalf("WorkspaceRuntimeDir() = %q, want %q", got, want)
	}
}

func TestAttemptCompleteMarkerPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	got, err := AttemptCompleteMarkerPath("scope", "loop-1")
	if err != nil {
		t.Fatalf("AttemptCompleteMarkerPath returned error: %v", err)
	}

	want := filepath.Join(home, ".algedonia", "workspaces", "scope", "runtime", "loop-1", "attempt_complete.json")
	if got != want {
		t.Fatalf("AttemptCompleteMarkerPath() = %q, want %q", got, want)
	}
}

func TestWorkspaceRuntimeDirRequiresWorkspace(t *testing.T) {
	if _, err := WorkspaceRuntimeDir(""); err == nil {
		t.Fatal("expected error for empty workspace")
	}
}
