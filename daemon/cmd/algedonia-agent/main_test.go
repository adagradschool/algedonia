package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/algedonia/daemon/internal/config"
)

func TestNormalizeServerWebsocketURL(t *testing.T) {
	prevProfile := activeProfile
	activeProfile = agProfile
	t.Cleanup(func() {
		activeProfile = prevProfile
	})

	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "https base becomes wss daemon websocket",
			in:   "https://algedonia.example.com",
			want: "wss://algedonia.example.com/daemon/websocket",
		},
		{
			name: "http base becomes ws daemon websocket",
			in:   "http://localhost:4000",
			want: "ws://localhost:4000/daemon/websocket",
		},
		{
			name: "ws path is preserved",
			in:   "ws://localhost:4000/custom/ws",
			want: "ws://localhost:4000/custom/ws",
		},
		{
			name: "invalid falls back",
			in:   "not a url",
			want: "ws://localhost:4000/daemon/websocket",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := normalizeServerWebsocketURL(tc.in); got != tc.want {
				t.Fatalf("normalizeServerWebsocketURL(%q)=%q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestDefaultServerWebsocketURLUsesBuildValue(t *testing.T) {
	prevProfile := activeProfile
	activeProfile = agProfile
	t.Cleanup(func() {
		activeProfile = prevProfile
	})

	orig := defaultServerURL
	defaultServerURL = "https://prod.algedonia.com"
	t.Cleanup(func() {
		defaultServerURL = orig
	})

	if got := defaultServerWebsocketURL(); got != "wss://prod.algedonia.com/daemon/websocket" {
		t.Fatalf("defaultServerWebsocketURL()=%q", got)
	}
}

func TestAGDProfileDefaults(t *testing.T) {
	prevProfile := activeProfile
	activeProfile = agdProfile
	t.Cleanup(func() {
		activeProfile = prevProfile
	})

	if got := defaultServerWebsocketURL(); got != "ws://localhost:4100/daemon/websocket" {
		t.Fatalf("defaultServerWebsocketURL()=%q, want ws://localhost:4100/daemon/websocket", got)
	}
	if got := normalizeServerWebsocketURL("not a url"); got != "ws://localhost:4100/daemon/websocket" {
		t.Fatalf("normalizeServerWebsocketURL fallback=%q, want ws://localhost:4100/daemon/websocket", got)
	}
	if got := defaultTerminalWSListen(); got != "127.0.0.1:8766" {
		t.Fatalf("defaultTerminalWSListen()=%q, want 127.0.0.1:8766", got)
	}
}

func TestInitCLIProfileSetsConfigNamespace(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	prevArgs := os.Args
	prevProfile := activeProfile
	config.SetProfile("ag")
	t.Cleanup(func() {
		os.Args = prevArgs
		activeProfile = prevProfile
		config.SetProfile("ag")
	})

	os.Args = []string{"/tmp/agd"}
	initCLIProfile()

	p, err := config.Path()
	if err != nil {
		t.Fatalf("config.Path: %v", err)
	}

	want := filepath.Join(tmp, ".config", "agd", "config.json")
	if p != want {
		t.Fatalf("config.Path()=%q, want %q", p, want)
	}
}

func TestWriteAttemptCompleteMarker_WritesForWorkRoles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	workspace := "scope"
	loopID := "loop-work-role"

	if err := writeAttemptCompleteMarker(workspace, loopID, "maker", "test-source", map[string]interface{}{"k": "v"}); err != nil {
		t.Fatalf("writeAttemptCompleteMarker returned error: %v", err)
	}

	markerPath := filepath.Join(home, ".algedonia", "workspaces", workspace, "runtime", loopID, "attempt_complete.json")
	raw, err := os.ReadFile(markerPath)
	if err != nil {
		t.Fatalf("expected marker file at %s: %v", markerPath, err)
	}

	var payload map[string]interface{}
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("marker payload is not valid json: %v", err)
	}

	if payload["loop_id"] != loopID {
		t.Fatalf("loop_id = %v, want %s", payload["loop_id"], loopID)
	}
	if payload["role"] != "maker" {
		t.Fatalf("role = %v, want maker", payload["role"])
	}
	if payload["source"] != "test-source" {
		t.Fatalf("source = %v, want test-source", payload["source"])
	}
}

func TestWriteAttemptCompleteMarker_SkipsPlanningRole(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	workspace := "scope"
	loopID := "loop-planning"

	if err := writeAttemptCompleteMarker(workspace, loopID, "planning", "test-source", nil); err != nil {
		t.Fatalf("writeAttemptCompleteMarker returned error: %v", err)
	}

	markerPath := filepath.Join(home, ".algedonia", "workspaces", workspace, "runtime", loopID, "attempt_complete.json")
	if _, err := os.Stat(markerPath); !os.IsNotExist(err) {
		t.Fatalf("expected no marker file for planning role, got err=%v", err)
	}
}

func TestWriteAttemptCompleteMarker_SkipsUnknownRole(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	workspace := "scope"
	loopID := "loop-unknown"

	if err := writeAttemptCompleteMarker(workspace, loopID, "", "test-source", nil); err != nil {
		t.Fatalf("writeAttemptCompleteMarker returned error: %v", err)
	}

	markerPath := filepath.Join(home, ".algedonia", "workspaces", workspace, "runtime", loopID, "attempt_complete.json")
	if _, err := os.Stat(markerPath); !os.IsNotExist(err) {
		t.Fatalf("expected no marker file for unknown role, got err=%v", err)
	}
}
