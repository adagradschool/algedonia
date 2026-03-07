package loopmanager

import (
	"context"
	"sync"
	"testing"
	"time"
)

func TestHandleStartLoopOverviewRouting(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")
	err := mgr.HandleStartLoop(context.Background(), map[string]interface{}{
		"loop_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
		"role":    "overview",
		"task":    "Generate overview",
	})
	if err == nil {
		t.Fatal("expected error for missing required scoped fields")
	}
}

func TestHandleStartLoopRequiresAgentType(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")
	err := mgr.HandleStartLoop(context.Background(), map[string]interface{}{
		"loop_id":        "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
		"role":           "maker",
		"task":           "do something",
		"workspace_slug": "scope",
		"ticket_id":      "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
	})
	if err == nil {
		t.Fatal("expected error when agent_type is missing")
	}
}

func TestHandleStartLoopWorkdirDefault(t *testing.T) {
	script := "#!/bin/sh\necho 'done'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, reg, dir)
	configureScopedWorktree(t, mgr, "scope")

	ctx := context.Background()
	// workdir is resolved from workspace_slug + ticket_id to the ticket worktree.
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id":        "ffffffff-ffff-4fff-8fff-ffffffffffff",
		"role":           "maker",
		"agent_type":     "claude_code",
		"task":           "do something",
		"workspace_slug": "scope",
		"ticket_id":      "12121212-1212-4212-8212-121212121212",
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

func TestHandleStartLoopRoleMissingScope(t *testing.T) {
	script := "#!/bin/sh\necho 'done'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, reg, dir)

	err := mgr.HandleStartLoop(context.Background(), map[string]interface{}{
		"loop_id":    "34343434-3434-4343-8343-343434343434",
		"role":       "maker",
		"agent_type": "claude_code",
		"task":       "do something",
	})
	if err == nil {
		t.Fatal("expected error for missing workspace_slug/ticket_id")
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
		"loop_id": "56565656-5656-4565-8565-565656565656",
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
		"loop_id": "78787878-7878-4787-8787-787878787878",
	})
}

type testError struct {
	msg string
}

func (e *testError) Error() string { return e.msg }
