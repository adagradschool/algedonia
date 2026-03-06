package adapter

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPromptPath(t *testing.T) {
	got := PromptPath("/foo/prompts", "maker")
	want := "/foo/prompts/maker.md"
	if got != want {
		t.Errorf("PromptPath = %q, want %q", got, want)
	}
}

func TestLoadPrompt(t *testing.T) {
	dir := t.TempDir()
	content := "# Test Prompt\nDo the thing."
	if err := os.WriteFile(filepath.Join(dir, "maker.md"), []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	got, err := LoadPrompt(dir, "maker")
	if err != nil {
		t.Fatalf("LoadPrompt: %v", err)
	}
	if got != content {
		t.Errorf("LoadPrompt = %q, want %q", got, content)
	}
}

func TestLoadPromptMissing(t *testing.T) {
	dir := t.TempDir()
	_, err := LoadPrompt(dir, "nonexistent")
	if err == nil {
		t.Fatal("expected error for missing prompt file")
	}
}

func TestLoadPromptVariousRoles(t *testing.T) {
	dir := t.TempDir()
	roles := []string{"maker", "checker", "reflect"}
	for _, role := range roles {
		content := "# " + role
		if err := os.WriteFile(filepath.Join(dir, role+".md"), []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}

	for _, role := range roles {
		got, err := LoadPrompt(dir, role)
		if err != nil {
			t.Errorf("LoadPrompt(%q): %v", role, err)
			continue
		}
		want := "# " + role
		if got != want {
			t.Errorf("LoadPrompt(%q) = %q, want %q", role, got, want)
		}
	}
}
