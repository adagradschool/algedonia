package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	// Use a temp dir as home so we don't touch real config.
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	// Load should return zero config when no file exists.
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load (missing): %v", err)
	}
	if cfg.ServerURL != "" || cfg.Token != "" || cfg.Name != "" {
		t.Fatalf("expected zero config, got %+v", cfg)
	}

	// Save a config.
	want := &Config{
		ServerURL: "ws://localhost:4000/daemon/websocket",
		Token:     "secret-token",
		Name:      "my-daemon",
	}
	if err := Save(want); err != nil {
		t.Fatalf("Save: %v", err)
	}

	// Verify file permissions.
	p, _ := Path()
	info, err := os.Stat(p)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("file perm = %o, want 600", perm)
	}

	// Load it back.
	got, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if *got != *want {
		t.Errorf("Load = %+v, want %+v", got, want)
	}

	// Remove and verify gone.
	if err := Remove(); err != nil {
		t.Fatalf("Remove: %v", err)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Errorf("config file still exists after Remove")
	}

	// Remove again should be a no-op.
	if err := Remove(); err != nil {
		t.Fatalf("Remove (idempotent): %v", err)
	}
}

func TestPathUnderHome(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	p, err := Path()
	if err != nil {
		t.Fatalf("Path: %v", err)
	}

	expected := filepath.Join(tmp, ".config", "ag", "config.json")
	if p != expected {
		t.Errorf("Path() = %q, want %q", p, expected)
	}
}
