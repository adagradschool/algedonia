package adapter

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCodexAdapterInterface(t *testing.T) {
	var _ AgentAdapter = (*CodexAdapter)(nil)
}

func TestCodexAdapterStartWithMockBinary(t *testing.T) {
	dir := t.TempDir()
	script := `#!/bin/sh
printf 'mock codex output\n'
sleep 1
exit 0
`
	if err := os.WriteFile(dir+"/codex", []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &CodexAdapter{}
	proc, err := a.Start(dir, "test task", map[string]string{
		"workspace_slug": "scope",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	if proc.SessionID == "" {
		t.Error("SessionID is empty")
	}

	// Drain PTY output and copy it to collector
	reader, _, _ := a.AttachPTY(proc)
	go io.Copy(io.MultiWriter(io.Discard, proc.Collector()), reader)

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
		if !strings.Contains(string(result.Output), "mock codex output") {
			t.Errorf("Output = %q, want to contain mock codex output", string(result.Output))
		}
	case <-time.After(5 * time.Second):
		a.Kill(proc)
		t.Fatal("Wait timed out")
	}
}

func TestCodexAdapterKill(t *testing.T) {
	dir := t.TempDir()
	script := `#!/bin/sh
printf 'running\n'
sleep 60
`
	if err := os.WriteFile(dir+"/codex", []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &CodexAdapter{}
	proc, err := a.Start(dir, "", map[string]string{
		"workspace_slug": "scope",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Drain PTY
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

func TestCodexAdapterStartRequiresWorkspaceSlug(t *testing.T) {
	dir := t.TempDir()
	a := &CodexAdapter{}
	if _, err := a.Start(dir, "task", nil); err == nil {
		t.Fatal("expected Start to fail when workspace_slug is missing")
	}
}

func TestCodexAdapterSpawnSkipsBrewUpdate(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "brew_update_called")

	codexScript := `#!/bin/sh
if [ "${HOMEBREW_NO_AUTO_UPDATE:-}" != "1" ]; then
  brew update
fi
printf 'codex-started\n'
exit 0
`
	if err := os.WriteFile(filepath.Join(dir, "codex"), []byte(codexScript), 0o755); err != nil {
		t.Fatal(err)
	}

	brewScript := "#!/bin/sh\n" +
		"touch '" + marker + "'\n" +
		"exit 0\n"
	if err := os.WriteFile(filepath.Join(dir, "brew"), []byte(brewScript), 0o755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &CodexAdapter{}
	proc, err := a.Start(dir, "task", map[string]string{
		"workspace_slug": "scope",
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
		t.Fatalf("ExitCode = %d, want 0", result.ExitCode)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("brew update marker exists, expected spawn to skip brew update")
	}
}
