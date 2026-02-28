package connection

import (
	"encoding/json"
	"testing"
)

func TestFormatJoinMessage(t *testing.T) {
	data, err := FormatJoinMessage("daemon:my-host", "secret", "my-host", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var msg PhoenixMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}

	if msg.Topic != "daemon:my-host" {
		t.Errorf("topic = %q, want %q", msg.Topic, "daemon:my-host")
	}
	if msg.Event != "phx_join" {
		t.Errorf("event = %q, want %q", msg.Event, "phx_join")
	}
	if msg.Ref != "1" {
		t.Errorf("ref = %q, want %q", msg.Ref, "1")
	}
	if msg.JoinRef != "1" {
		t.Errorf("join_ref = %q, want %q", msg.JoinRef, "1")
	}

	payload, ok := msg.Payload.(map[string]interface{})
	if !ok {
		t.Fatal("payload is not a map")
	}
	if payload["name"] != "my-host" {
		t.Errorf("payload.name = %q, want %q", payload["name"], "my-host")
	}
	if payload["display_name"] != "my-host" {
		t.Errorf("payload.display_name = %q, want %q", payload["display_name"], "my-host")
	}
}

func TestFormatHeartbeat(t *testing.T) {
	data, err := FormatHeartbeat("5")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var msg PhoenixMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}

	if msg.Topic != "phoenix" {
		t.Errorf("topic = %q, want %q", msg.Topic, "phoenix")
	}
	if msg.Event != "heartbeat" {
		t.Errorf("event = %q, want %q", msg.Event, "heartbeat")
	}
	if msg.Ref != "5" {
		t.Errorf("ref = %q, want %q", msg.Ref, "5")
	}
	if msg.JoinRef != "" {
		t.Errorf("join_ref = %q, want empty", msg.JoinRef)
	}
}

func TestFormatAppHeartbeat(t *testing.T) {
	data, err := FormatAppHeartbeat("daemon:host1", 5, 2, "10", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var msg PhoenixMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}

	if msg.Topic != "daemon:host1" {
		t.Errorf("topic = %q, want %q", msg.Topic, "daemon:host1")
	}
	if msg.Event != "heartbeat" {
		t.Errorf("event = %q, want %q", msg.Event, "heartbeat")
	}
	if msg.JoinRef != "1" {
		t.Errorf("join_ref = %q, want %q", msg.JoinRef, "1")
	}

	payload, ok := msg.Payload.(map[string]interface{})
	if !ok {
		t.Fatal("payload is not a map")
	}
	if payload["capacity"] != float64(5) {
		t.Errorf("capacity = %v, want 5", payload["capacity"])
	}
	if payload["running_loops"] != float64(2) {
		t.Errorf("running_loops = %v, want 2", payload["running_loops"])
	}
}

func TestNewClient(t *testing.T) {
	c := NewClient("ws://localhost:4000/daemon/websocket", "tok", "host1", "my-workspace", 5)
	if c.serverURL != "ws://localhost:4000/daemon/websocket" {
		t.Errorf("serverURL = %q", c.serverURL)
	}
	if c.token != "tok" {
		t.Errorf("token = %q", c.token)
	}
	if c.name != "host1" {
		t.Errorf("name = %q", c.name)
	}
	if c.capacity != 5 {
		t.Errorf("capacity = %d, want 5", c.capacity)
	}
}

func TestNextRef(t *testing.T) {
	c := NewClient("", "", "", "", 0)
	r1 := c.nextRef()
	r2 := c.nextRef()
	if r1 == r2 {
		t.Errorf("refs should be unique, got %q twice", r1)
	}
}

func TestTopic(t *testing.T) {
	c := NewClient("", "", "myhost", "", 0)
	if c.topic() != "daemon:myhost" {
		t.Errorf("topic() = %q, want %q", c.topic(), "daemon:myhost")
	}
}
