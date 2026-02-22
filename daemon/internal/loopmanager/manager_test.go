package loopmanager

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
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

	mgr := NewManager(collectingSendFunc(&mu, &events))

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
	mgr := NewManager(func(string, map[string]interface{}) error { return nil })

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

	mgr := NewManager(collectingSendFunc(&mu, &events))

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
	mgr := NewManager(func(string, map[string]interface{}) error { return nil })

	err := mgr.StopLoop("nonexistent", "test")
	if err == nil {
		t.Fatal("expected error for nonexistent loop")
	}
}

func TestHandleStartLoop(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil })

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
	mgr := NewManager(func(string, map[string]interface{}) error { return nil })

	err := mgr.HandleStartLoop(context.Background(), map[string]interface{}{})
	if err == nil {
		t.Fatal("expected error for missing loop_id")
	}
}

func TestHandleStopLoop(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil })

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

	mgr := NewManager(collectingSendFunc(&mu, &events))

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
	mgr := NewManager(func(string, map[string]interface{}) error { return nil })

	err := mgr.SendInput("nonexistent", []byte("data"))
	if err == nil {
		t.Fatal("expected error for nonexistent loop")
	}
}

func TestHandleStdinInput(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events))

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
	mgr := NewManager(func(string, map[string]interface{}) error { return nil })

	err := mgr.HandleStdinInput(context.Background(), map[string]interface{}{})
	if err == nil {
		t.Fatal("expected error for missing loop_id")
	}
}

func TestSendFuncError(t *testing.T) {
	// SendFunc that always fails — manager should still function
	mgr := NewManager(func(string, map[string]interface{}) error {
		return fmt.Errorf("send failed")
	})

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
