package loopmanager

import (
	"context"
	"sync"
	"testing"
	"time"
)

func TestHandleStartLoopOverviewRouting(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	// Overview requires claude binary — use a mock
	script := "#!/bin/sh\necho 'overview output'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id": "overview-test",
		"role":    "overview",
		"task":    "Generate overview",
		"model":   "test-model",
	})
	if err != nil {
		t.Fatalf("HandleStartLoop overview: %v", err)
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

	// Should have loop_exited (overview uses StartOverviewLoop which sends loop_exited)
	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, e := range events {
		if e.Event == "loop_exited" && e.Payload["loop_id"] == "overview-test" {
			found = true
		}
	}
	if !found {
		t.Error("expected loop_exited event for overview")
		for _, e := range events {
			t.Logf("  event: %s %v", e.Event, e.Payload)
		}
	}
}

func TestHandleStartLoopDefaultAgentType(t *testing.T) {
	// When agent_type is empty and role is set, should default to defaultCodingAgent()
	script := "#!/bin/sh\necho 'done'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, reg, dir)

	ctx := context.Background()
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id": "default-agent-test",
		"role":    "maker",
		// agent_type intentionally omitted
		"task":    "do something",
		"workdir": dir,
	})
	if err != nil {
		t.Fatalf("HandleStartLoop: %v", err)
	}

	// Wait for completion — if it started, the default worked
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

func TestHandleStartLoopWorkdirDefault(t *testing.T) {
	script := "#!/bin/sh\necho 'done'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, reg, dir)

	ctx := context.Background()
	// workdir empty — should fall back to repoRoot (dir)
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id":    "workdir-test",
		"role":       "maker",
		"agent_type": "claude_code",
		"task":       "do something",
		// workdir intentionally omitted
	})
	if err != nil {
		t.Fatalf("HandleStartLoop: %v", err)
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
}

func TestPayloadStr(t *testing.T) {
	tests := []struct {
		name     string
		payload  map[string]interface{}
		key      string
		expected string
	}{
		{"existing string key", map[string]interface{}{"foo": "bar"}, "foo", "bar"},
		{"missing key", map[string]interface{}{}, "foo", ""},
		{"non-string value", map[string]interface{}{"foo": 42}, "foo", ""},
		{"nil value", map[string]interface{}{"foo": nil}, "foo", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := payloadStr(tt.payload, tt.key)
			if got != tt.expected {
				t.Errorf("payloadStr(%v, %q) = %q, want %q", tt.payload, tt.key, got, tt.expected)
			}
		})
	}
}

func TestSendEvent(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	mgr.sendEvent("test_event", map[string]interface{}{
		"loop_id": "test-loop",
		"data":    "hello",
	})

	mu.Lock()
	defer mu.Unlock()

	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Event != "test_event" {
		t.Errorf("event = %q, want %q", events[0].Event, "test_event")
	}
}

func TestSendEventErrorDoesNotPanic(t *testing.T) {
	// sendEvent with a failing sendFunc should log but not panic
	mgr := NewManager(func(string, map[string]interface{}) error {
		return &testError{"send failed"}
	}, nil, "")

	// Should not panic
	mgr.sendEvent("test_event", map[string]interface{}{
		"loop_id": "test-loop",
	})
}

type testError struct {
	msg string
}

func (e *testError) Error() string { return e.msg }
