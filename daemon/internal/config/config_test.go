package config

import (
	"os"
	"path/filepath"
	"testing"
)

func withProfile(t *testing.T, profile string) {
	t.Helper()
	SetProfile(profile)
	t.Cleanup(func() {
		SetProfile("ag")
	})
}

func TestRoundTrip(t *testing.T) {
	// Use a temp dir as home so we don't touch real config.
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	withProfile(t, "ag")

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
	withProfile(t, "ag")

	p, err := Path()
	if err != nil {
		t.Fatalf("Path: %v", err)
	}

	expected := filepath.Join(tmp, ".config", "ag", "config.json")
	if p != expected {
		t.Errorf("Path() = %q, want %q", p, expected)
	}
}

func TestPathUsesProfileNamespace(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	withProfile(t, "agd")

	p, err := Path()
	if err != nil {
		t.Fatalf("Path: %v", err)
	}

	expected := filepath.Join(tmp, ".config", "agd", "config.json")
	if p != expected {
		t.Errorf("Path() = %q, want %q", p, expected)
	}
}

func TestProfilesPersistIndependently(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	t.Cleanup(func() {
		SetProfile("ag")
	})

	SetProfile("ag")
	if err := Save(&Config{Token: "ag-token", ServerURL: "ws://localhost:4000/daemon/websocket"}); err != nil {
		t.Fatalf("Save ag: %v", err)
	}

	SetProfile("agd")
	agdCfg, err := Load()
	if err != nil {
		t.Fatalf("Load agd before save: %v", err)
	}
	if agdCfg.Token != "" || agdCfg.ServerURL != "" {
		t.Fatalf("expected empty agd config before save, got %+v", agdCfg)
	}
	if err := Save(&Config{Token: "agd-token", ServerURL: "ws://localhost:4100/daemon/websocket"}); err != nil {
		t.Fatalf("Save agd: %v", err)
	}

	SetProfile("ag")
	agCfg, err := Load()
	if err != nil {
		t.Fatalf("Load ag: %v", err)
	}
	if agCfg.Token != "ag-token" {
		t.Fatalf("ag token = %q, want ag-token", agCfg.Token)
	}
	if agCfg.ServerURL != "ws://localhost:4000/daemon/websocket" {
		t.Fatalf("ag server url = %q", agCfg.ServerURL)
	}

	SetProfile("agd")
	agdCfg, err = Load()
	if err != nil {
		t.Fatalf("Load agd: %v", err)
	}
	if agdCfg.Token != "agd-token" {
		t.Fatalf("agd token = %q, want agd-token", agdCfg.Token)
	}
	if agdCfg.ServerURL != "ws://localhost:4100/daemon/websocket" {
		t.Fatalf("agd server url = %q", agdCfg.ServerURL)
	}
}
