package loopmanager

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
)

type sentEvent struct {
	Event   string
	Payload map[string]interface{}
}

func collectingSendFunc(mu *sync.Mutex, events *[]sentEvent) func(string, map[string]interface{}) error {
	return func(event string, payload map[string]interface{}) error {
		mu.Lock()
		defer mu.Unlock()
		*events = append(*events, sentEvent{Event: event, Payload: payload})
		return nil
	}
}

func TestManagerStartAndWait(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "loop-1", "echo", []string{"hello from loop"}, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}

	// Wait for process to exit
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for loop to exit")
		default:
		}

		mu.Lock()
		found := false
		for _, e := range events {
			if e.Event == "loop_exited" {
				found = true
				break
			}
		}
		mu.Unlock()

		if found {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Verify we got terminal_output and loop_exited
	mu.Lock()
	defer mu.Unlock()

	var hasOutput, hasExited bool
	var outputData string
	for _, e := range events {
		switch e.Event {
		case "terminal_output":
			if e.Payload["loop_id"] != "loop-1" {
				t.Errorf("terminal_output loop_id = %v, want loop-1", e.Payload["loop_id"])
			}
			if encoded, ok := e.Payload["data"].(string); ok {
				decoded, _ := base64.StdEncoding.DecodeString(encoded)
				outputData += string(decoded)
			}
			hasOutput = true
		case "loop_exited":
			if e.Payload["loop_id"] != "loop-1" {
				t.Errorf("loop_exited loop_id = %v, want loop-1", e.Payload["loop_id"])
			}
			exitCode, ok := e.Payload["exit_code"]
			if !ok {
				t.Error("loop_exited missing exit_code")
			}
			// JSON numbers come as float64 from interface{}
			if code, ok := exitCode.(int); ok && code != 0 {
				t.Errorf("exit_code = %v, want 0", code)
			}
			hasExited = true
		}
	}

	if !hasOutput {
		t.Error("no terminal_output event received")
	}
	if !hasExited {
		t.Error("no loop_exited event received")
	}
	if !strings.Contains(outputData, "hello from loop") {
		t.Errorf("output = %q, want it to contain %q", outputData, "hello from loop")
	}

	// Running count should be 0 after exit
	if mgr.RunningCount() != 0 {
		t.Errorf("RunningCount() = %d, want 0", mgr.RunningCount())
	}
}

func TestManagerDuplicateStart(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "loop-dup", "sleep", []string{"10"}, "", "")
	if err != nil {
		t.Fatalf("first StartLoop: %v", err)
	}
	defer mgr.StopLoop("loop-dup", "test cleanup")

	err = mgr.StartLoop(ctx, "loop-dup", "echo", []string{"hi"}, "", "")
	if err == nil {
		t.Fatal("expected error for duplicate loop ID")
	}
}

func TestManagerStopLoop(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "loop-stop", "sleep", []string{"60"}, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}

	if mgr.RunningCount() != 1 {
		t.Errorf("RunningCount() = %d, want 1", mgr.RunningCount())
	}

	err = mgr.StopLoop("loop-stop", "test")
	if err != nil {
		t.Fatalf("StopLoop: %v", err)
	}

	// Process should be gone
	if mgr.RunningCount() != 0 {
		t.Errorf("RunningCount() = %d after stop, want 0", mgr.RunningCount())
	}

	// Should have loop_exited event
	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, e := range events {
		if e.Event == "loop_exited" && e.Payload["loop_id"] == "loop-stop" {
			found = true
		}
	}
	if !found {
		t.Error("no loop_exited event after StopLoop")
	}
}

func TestManagerStopNotFound(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	err := mgr.StopLoop("nonexistent", "test")
	if err == nil {
		t.Fatal("expected error for nonexistent loop")
	}
}

func TestHandleStartLoop(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	ctx := context.Background()
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id": "handle-test",
		"command": "echo",
		"args":    []interface{}{"handled"},
	})
	if err != nil {
		t.Fatalf("HandleStartLoop: %v", err)
	}

	// Wait for it to exit
	time.Sleep(500 * time.Millisecond)
}

func TestHandleStartLoopMissingID(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	err := mgr.HandleStartLoop(context.Background(), map[string]interface{}{})
	if err == nil {
		t.Fatal("expected error for missing loop_id")
	}
}

func TestHandleStopLoop(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	ctx := context.Background()
	_ = mgr.StartLoop(ctx, "handle-stop-test", "sleep", []string{"60"}, "", "")

	err := mgr.HandleStopLoop(ctx, map[string]interface{}{
		"loop_id": "handle-stop-test",
		"reason":  "test",
	})
	if err != nil {
		t.Fatalf("HandleStopLoop: %v", err)
	}
}

func TestSendInput(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	ctx := context.Background()
	// Start cat — it echoes stdin back to stdout via PTY
	err := mgr.StartLoop(ctx, "loop-stdin", "cat", nil, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	defer mgr.StopLoop("loop-stdin", "test cleanup")

	// Give cat time to start
	time.Sleep(300 * time.Millisecond)

	err = mgr.SendInput("loop-stdin", []byte("hello\n"))
	if err != nil {
		t.Fatalf("SendInput: %v", err)
	}

	// Wait for the echo to appear in terminal_output
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for echoed output")
		default:
		}

		mu.Lock()
		var output string
		for _, e := range events {
			if e.Event == "terminal_output" {
				if encoded, ok := e.Payload["data"].(string); ok {
					decoded, _ := base64.StdEncoding.DecodeString(encoded)
					output += string(decoded)
				}
			}
		}
		mu.Unlock()

		if strings.Contains(output, "hello") {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestSendInputNotFound(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	err := mgr.SendInput("nonexistent", []byte("data"))
	if err == nil {
		t.Fatal("expected error for nonexistent loop")
	}
}

func TestHandleStdinInput(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "loop-handler-stdin", "cat", nil, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	defer mgr.StopLoop("loop-handler-stdin", "test cleanup")

	time.Sleep(300 * time.Millisecond)

	encoded := base64.StdEncoding.EncodeToString([]byte("world\n"))
	err = mgr.HandleStdinInput(ctx, map[string]interface{}{
		"loop_id": "loop-handler-stdin",
		"data":    encoded,
	})
	if err != nil {
		t.Fatalf("HandleStdinInput: %v", err)
	}

	// Wait for echo
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for echoed output")
		default:
		}

		mu.Lock()
		var output string
		for _, e := range events {
			if e.Event == "terminal_output" {
				if enc, ok := e.Payload["data"].(string); ok {
					decoded, _ := base64.StdEncoding.DecodeString(enc)
					output += string(decoded)
				}
			}
		}
		mu.Unlock()

		if strings.Contains(output, "world") {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestHandleStdinInputMissingID(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	err := mgr.HandleStdinInput(context.Background(), map[string]interface{}{})
	if err == nil {
		t.Fatal("expected error for missing loop_id")
	}
}

func TestSendFuncError(t *testing.T) {
	// SendFunc that always fails — manager should still function
	mgr := NewManager(func(string, map[string]interface{}) error {
		return fmt.Errorf("send failed")
	}, nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "send-fail", "echo", []string{"hello"}, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}

	// Wait for exit — should not deadlock
	deadline := time.After(3 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// setupMockAgent creates a mock agent binary and returns a registry + workdir.
func setupMockAgent(t *testing.T, agentName, script string) (*adapter.Registry, string) {
	t.Helper()
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, agentName)
	if err := os.WriteFile(scriptPath, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	t.Cleanup(func() { os.Setenv("PATH", origPath) })

	return adapter.DefaultRegistry(), dir
}

func TestStartLoopWithAdapter(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	script := "#!/bin/sh\necho 'adapter output'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	err := mgr.StartLoopWithAdapter(ctx, "adapter-loop", "claude_code", "maker", dir, "do a thing", 1)
	if err != nil {
		t.Fatalf("StartLoopWithAdapter: %v", err)
	}

	// Wait for completion
	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for adapter loop to finish")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Should have gotten attempt_complete (exit code 0, non-decompose role)
	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, e := range events {
		if e.Event == "attempt_complete" && e.Payload["loop_id"] == "adapter-loop" {
			found = true
		}
	}
	if !found {
		t.Error("expected attempt_complete event")
		for _, e := range events {
			t.Logf("  event: %s %v", e.Event, e.Payload)
		}
	}
}

func TestHandleStartLoopWithRole(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	script := "#!/bin/sh\necho 'hello from adapter'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id":    "role-test",
		"role":       "maker",
		"agent_type": "claude_code",
		"workdir":    dir,
		"task":       "implement feature X",
	})
	if err != nil {
		t.Fatalf("HandleStartLoop with role: %v", err)
	}

	// Wait for completion
	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestHandleStartLoopWithoutRole(t *testing.T) {
	// Backward compatible — no role = legacy raw process path
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	ctx := context.Background()
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id": "legacy-test",
		"command": "echo",
		"args":    []interface{}{"legacy"},
	})
	if err != nil {
		t.Fatalf("HandleStartLoop without role: %v", err)
	}

	time.Sleep(500 * time.Millisecond)
}

func TestDecomposeOutputParsing(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	dagJSON := `---ALGEDONIA_DAG_BEGIN---
{"loops":[{"id":"l1","title":"Step 1","description":"Do step 1","rubric":"Works","path_hints":["a.go"]}],"dependencies":[]}
---ALGEDONIA_DAG_END---`

	script := "#!/bin/sh\necho '" + dagJSON + "'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	err := mgr.StartLoopWithAdapter(ctx, "decompose-loop", "claude_code", "decompose", dir, "decompose this ticket", 1)
	if err != nil {
		t.Fatalf("StartLoopWithAdapter: %v", err)
	}

	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()

	var foundResult bool
	for _, e := range events {
		if e.Event == "loop_result" && e.Payload["loop_id"] == "decompose-loop" {
			foundResult = true
			if e.Payload["verdict"] != "pass" {
				t.Errorf("verdict = %v, want pass", e.Payload["verdict"])
			}
			if e.Payload["dag"] == nil {
				t.Error("dag is nil in loop_result")
			}
		}
	}
	if !foundResult {
		t.Error("expected loop_result event for decompose")
		for _, e := range events {
			t.Logf("  event: %s %v", e.Event, e.Payload)
		}
	}
}

func TestAgentCrashReportsError(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	script := "#!/bin/sh\nexit 1\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	err := mgr.StartLoopWithAdapter(ctx, "crash-loop", "claude_code", "maker", dir, "do a thing", 1)
	if err != nil {
		t.Fatalf("StartLoopWithAdapter: %v", err)
	}

	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()

	found := false
	for _, e := range events {
		if e.Event == "error" && e.Payload["loop_id"] == "crash-loop" {
			found = true
			if e.Payload["recoverable"] != true {
				t.Errorf("recoverable = %v, want true", e.Payload["recoverable"])
			}
		}
	}
	if !found {
		t.Error("expected error event for crashed agent")
		for _, e := range events {
			t.Logf("  event: %s %v", e.Event, e.Payload)
		}
	}
}
