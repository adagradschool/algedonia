package adapter

import (
	"io"
	"os"
	"testing"
	"time"
)

func TestCodexAdapterInterface(t *testing.T) {
	var _ AgentAdapter = (*CodexAdapter)(nil)
}

func TestCodexAdapterStartWithMockBinary(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\necho 'mock codex output'\n"
	if err := os.WriteFile(dir+"/codex", []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &CodexAdapter{}
	proc, err := a.Start(dir, "test task", nil)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	if proc.SessionID == "" {
		t.Error("SessionID is empty")
	}

	// Drain PTY output
	reader, _, _ := a.AttachPTY(proc)
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
	case <-time.After(5 * time.Second):
		a.Kill(proc)
		t.Fatal("Wait timed out")
	}
}

func TestCodexAdapterKill(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\nsleep 60\n"
	if err := os.WriteFile(dir+"/codex", []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	defer os.Setenv("PATH", origPath)

	a := &CodexAdapter{}
	proc, err := a.Start(dir, "", nil)
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
