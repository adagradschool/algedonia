package adapter

import (
	"io"
	"os"
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
if [ "$1" != "app-server" ]; then
  exit 1
fi
n=0
while IFS= read -r line; do
  if echo "$line" | grep -q 'initialize'; then
    printf '{"jsonrpc":"2.0","id":"1","result":{}}\n'
  elif echo "$line" | grep -q 'thread/start'; then
    printf '{"jsonrpc":"2.0","id":"2","result":{"thread":{"id":"thread-1"}}}\n'
  elif echo "$line" | grep -q 'turn/start'; then
    printf '{"jsonrpc":"2.0","id":"3","result":{"turn":{"id":"turn-1"}}}\n'
    printf '{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"delta":"mock codex output"}}\n'
    printf '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}\n'
    exit 0
  elif echo "$line" | grep -q 'turn/interrupt'; then
    printf '{"jsonrpc":"2.0","id":"4","result":{}}\n'
  elif echo "$line" | grep -q 'turn/steer'; then
    printf '{"jsonrpc":"2.0","id":"5","result":{}}\n'
  fi
done
`
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
if [ "$1" != "app-server" ]; then
  exit 1
fi
n=0
while IFS= read -r line; do
  if echo "$line" | grep -q 'initialize'; then
    printf '{"jsonrpc":"2.0","id":"1","result":{}}\n'
  elif echo "$line" | grep -q 'thread/start'; then
    printf '{"jsonrpc":"2.0","id":"2","result":{"thread":{"id":"thread-1"}}}\n'
  elif echo "$line" | grep -q 'turn/start'; then
    printf '{"jsonrpc":"2.0","id":"3","result":{"turn":{"id":"turn-1"}}}\n'
    # keep process alive until killed
    sleep 60
  elif echo "$line" | grep -q 'turn/interrupt'; then
    printf '{"jsonrpc":"2.0","id":"4","result":{}}\n'
  elif echo "$line" | grep -q 'turn/steer'; then
    printf '{"jsonrpc":"2.0","id":"5","result":{}}\n'
  fi
done
`
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
