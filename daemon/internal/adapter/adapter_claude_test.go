package adapter

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestClaudeCodeAdapterInterface(t *testing.T) {
	var _ AgentAdapter = (*ClaudeCodeAdapter)(nil)
}

func TestClaudeCodeAdapterStartWithMockBinary(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\necho 'mock claude output'\n"
	if err := os.WriteFile(dir+"/claude", []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &ClaudeCodeAdapter{}
	proc, err := a.Start(dir, "test task", map[string]string{
		"workspace_slug": "scope",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	if proc.SessionID == "" {
		t.Error("SessionID is empty")
	}
	if proc.Workdir != dir {
		t.Errorf("Workdir = %q, want %q", proc.Workdir, dir)
	}

	sid := a.SessionID(proc)
	if sid != proc.SessionID {
		t.Errorf("SessionID() = %q, want %q", sid, proc.SessionID)
	}

	// Drain PTY output (required — process blocks if PTY master is not read)
	reader, _, err := a.AttachPTY(proc)
	if err != nil {
		t.Fatalf("AttachPTY: %v", err)
	}
	go io.Copy(io.Discard, reader)

	done := make(chan *ExitResult, 1)
	errCh := make(chan error, 1)
	go func() {
		r, e := a.Wait(proc)
		done <- r
		errCh <- e
	}()

	select {
	case result := <-done:
		if err := <-errCh; err != nil {
			t.Fatalf("Wait: %v", err)
		}
		if result.ExitCode != 0 {
			t.Errorf("ExitCode = %d, want 0", result.ExitCode)
		}
		if result.SessionID != proc.SessionID {
			t.Errorf("result.SessionID = %q, want %q", result.SessionID, proc.SessionID)
		}
	case <-time.After(5 * time.Second):
		a.Kill(proc)
		t.Fatal("Wait timed out")
	}
}

func TestClaudeCodeAdapterAttachPTY(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\nsleep 10\n"
	if err := os.WriteFile(dir+"/claude", []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &ClaudeCodeAdapter{}
	proc, err := a.Start(dir, "", map[string]string{
		"workspace_slug": "scope",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer a.Kill(proc)

	reader, writer, err := a.AttachPTY(proc)
	if err != nil {
		t.Fatalf("AttachPTY: %v", err)
	}
	if reader == nil {
		t.Error("reader is nil")
	}
	if writer == nil {
		t.Error("writer is nil")
	}
	// Drain so Kill doesn't hang
	go io.Copy(io.Discard, reader)
}

func TestClaudeCodeAdapterKill(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\nsleep 60\n"
	if err := os.WriteFile(dir+"/claude", []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &ClaudeCodeAdapter{}
	proc, err := a.Start(dir, "", map[string]string{
		"workspace_slug": "scope",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Drain PTY output so kill doesn't hang
	reader, _, _ := a.AttachPTY(proc)
	go io.Copy(io.Discard, reader)

	done := make(chan struct{})
	go func() {
		a.Kill(proc)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Kill did not return in time")
	}
}

func TestClaudeCodeCLIConstruction(t *testing.T) {
	_, err := exec.LookPath("claude")
	if err != nil {
		t.Skip("claude not on PATH, skipping CLI construction test")
	}
}

func TestClaudeCodeAdapterStartRequiresWorkspaceSlug(t *testing.T) {
	dir := t.TempDir()
	a := &ClaudeCodeAdapter{}
	if _, err := a.Start(dir, "task", nil); err == nil {
		t.Fatal("expected Start to fail when workspace_slug is missing")
	}
}

func TestClaudeCodeAdapterWaitReturnsOnHookMarker(t *testing.T) {
	dir := t.TempDir()
	home := t.TempDir()
	t.Setenv("HOME", home)
	script := "#!/bin/sh\nsleep 60\n"
	if err := os.WriteFile(dir+"/claude", []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &ClaudeCodeAdapter{}
	proc, err := a.Start(dir, "", map[string]string{
		"workspace_slug": "scope",
		"loop_id":        "loop-hook-1",
		"role":           "checker",
		"workdir":        dir,
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	reader, _, err := a.AttachPTY(proc)
	if err != nil {
		t.Fatalf("AttachPTY: %v", err)
	}
	go io.Copy(io.Discard, reader)

	go func() {
		time.Sleep(500 * time.Millisecond)
		markerPath := filepath.Join(home, ".algedonia", "workspaces", "scope", "runtime", "loop-hook-1", "attempt_complete.json")
		_ = os.MkdirAll(filepath.Dir(markerPath), 0o755)
		data, _ := json.Marshal(map[string]string{
			"loop_id":   "loop-hook-1",
			"role":      "checker",
			"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
		})
		_ = os.WriteFile(markerPath, data, 0o644)
	}()

	done := make(chan *ExitResult, 1)
	errCh := make(chan error, 1)
	go func() {
		r, e := a.Wait(proc)
		done <- r
		errCh <- e
	}()

	select {
	case result := <-done:
		if err := <-errCh; err != nil {
			t.Fatalf("Wait: %v", err)
		}
		if result.ExitCode != 0 {
			t.Fatalf("ExitCode = %d, want 0", result.ExitCode)
		}
	case <-time.After(10 * time.Second):
		_ = a.Kill(proc)
		t.Fatal("Wait timed out; hook marker did not complete process")
	}
}

func TestClaudeCodeAdapterWaitPrefersMarkerOverNonZeroExit(t *testing.T) {
	dir := t.TempDir()
	home := t.TempDir()
	t.Setenv("HOME", home)
	script := `#!/bin/sh
mkdir -p "$ALGEDONIA_RUNTIME_DIR/$ALGEDONIA_LOOP_ID"
cat > "$ALGEDONIA_RUNTIME_DIR/$ALGEDONIA_LOOP_ID/attempt_complete.json" <<'EOF'
{"loop_id":"loop-hook-race","role":"maker","source":"test"}
EOF
exit 1
`
	if err := os.WriteFile(dir+"/claude", []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &ClaudeCodeAdapter{}
	proc, err := a.Start(dir, "", map[string]string{
		"workspace_slug": "scope",
		"loop_id":        "loop-hook-race",
		"role":           "maker",
		"workdir":        dir,
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	reader, _, err := a.AttachPTY(proc)
	if err != nil {
		t.Fatalf("AttachPTY: %v", err)
	}
	go io.Copy(io.Discard, reader)

	result, err := a.Wait(proc)
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}

	if result.ExitCode != 0 {
		t.Fatalf("ExitCode = %d, want 0 when completion marker exists", result.ExitCode)
	}
}
