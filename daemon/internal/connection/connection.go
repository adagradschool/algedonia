// Package connection handles the persistent WebSocket/Channel connection to the Phoenix server.
package connection

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"nhooyr.io/websocket"
)

// PhoenixMessage is the wire format for Phoenix channel messages.
type PhoenixMessage struct {
	Topic   string      `json:"topic"`
	Event   string      `json:"event"`
	Payload interface{} `json:"payload"`
	Ref     string      `json:"ref"`
	JoinRef string      `json:"join_ref,omitempty"`
}

// Client manages a persistent connection to the Phoenix server.
type Client struct {
	serverURL string
	token     string
	name      string
	capacity  int
	ref       atomic.Int64
	joinRef   string

	connMu   sync.RWMutex
	conn     *websocket.Conn
	connCtx  context.Context
	handlers map[string]func(ctx context.Context, payload map[string]interface{}) error

	runningLoopsFn func() int
}

// NewClient creates a new connection client.
func NewClient(serverURL, token, name string, capacity int) *Client {
	return &Client{
		serverURL: serverURL,
		token:     token,
		name:      name,
		capacity:  capacity,
		handlers:  make(map[string]func(ctx context.Context, payload map[string]interface{}) error),
	}
}

// RegisterHandler registers a handler for a specific event type from the server.
func (c *Client) RegisterHandler(event string, handler func(ctx context.Context, payload map[string]interface{}) error) {
	c.handlers[event] = handler
}

// SetRunningLoopsFn sets the function used to report running loop count in heartbeats.
func (c *Client) SetRunningLoopsFn(fn func() int) {
	c.runningLoopsFn = fn
}

// SendEvent sends an event to the server on the daemon topic. Thread-safe.
func (c *Client) SendEvent(event string, payload map[string]interface{}) error {
	c.connMu.RLock()
	conn := c.conn
	ctx := c.connCtx
	c.connMu.RUnlock()

	if conn == nil {
		return fmt.Errorf("not connected")
	}

	return c.send(ctx, conn, c.topic(), event, payload, c.nextRef())
}

func (c *Client) nextRef() string {
	return fmt.Sprintf("%d", c.ref.Add(1))
}

func (c *Client) topic() string {
	return "daemon:" + c.name
}

// RunForever connects to the server and reconnects with exponential backoff on failure.
func (c *Client) RunForever(ctx context.Context) error {
	backoff := time.Second

	for {
		err := c.run(ctx)
		if ctx.Err() != nil {
			return nil
		}

		log.Printf("Connection lost: %v. Reconnecting in %v...", err, backoff)

		select {
		case <-ctx.Done():
			return nil
		case <-time.After(backoff):
		}

		backoff *= 2
		if backoff > 30*time.Second {
			backoff = 30 * time.Second
		}
	}
}

func (c *Client) run(ctx context.Context) error {
	conn, _, err := websocket.Dial(ctx, c.serverURL+fmt.Sprintf("?token=%s&daemon_id=%s&daemon_name=%s", c.token, c.name, c.name), nil)
	if err != nil {
		return fmt.Errorf("dialing server: %w", err)
	}
	defer conn.CloseNow()

	c.connMu.Lock()
	c.conn = conn
	c.connCtx = ctx
	c.connMu.Unlock()

	defer func() {
		c.connMu.Lock()
		c.conn = nil
		c.connCtx = nil
		c.connMu.Unlock()
	}()

	// Join channel
	c.joinRef = c.nextRef()
	joinPayload := map[string]interface{}{
		"display_name": c.name,
	}

	if err := c.send(ctx, conn, c.topic(), "phx_join", joinPayload, c.joinRef); err != nil {
		return fmt.Errorf("sending join: %w", err)
	}

	// Read join reply
	reply, err := c.receive(ctx, conn)
	if err != nil {
		return fmt.Errorf("reading join reply: %w", err)
	}

	if reply.Event == "phx_reply" {
		payload, ok := reply.Payload.(map[string]interface{})
		if ok && payload["status"] != "ok" {
			return fmt.Errorf("join rejected: %v", payload)
		}
	}

	log.Printf("Connected and joined as %q", c.name)

	// Reset backoff on successful connection
	// Start heartbeat and listen loops
	errCh := make(chan error, 2)

	// Phoenix-level heartbeat (keeps WebSocket alive)
	go func() {
		errCh <- c.phoenixHeartbeatLoop(ctx, conn)
	}()

	// App-level heartbeat (reports daemon metrics)
	go func() {
		errCh <- c.appHeartbeatLoop(ctx, conn)
	}()

	// Listen for server pushes
	go func() {
		errCh <- c.listenLoop(ctx, conn)
	}()

	select {
	case <-ctx.Done():
		// Send leave message
		_ = c.send(ctx, conn, c.topic(), "phx_leave", map[string]interface{}{}, c.nextRef())
		conn.Close(websocket.StatusNormalClosure, "shutdown")
		return nil
	case err := <-errCh:
		return err
	}
}

func (c *Client) phoenixHeartbeatLoop(ctx context.Context, conn *websocket.Conn) error {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if err := c.send(ctx, conn, "phoenix", "heartbeat", map[string]interface{}{}, c.nextRef()); err != nil {
				return fmt.Errorf("phoenix heartbeat: %w", err)
			}
		}
	}
}

func (c *Client) appHeartbeatLoop(ctx context.Context, conn *websocket.Conn) error {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			runningLoops := 0
			if c.runningLoopsFn != nil {
				runningLoops = c.runningLoopsFn()
			}
			payload := map[string]interface{}{
				"capacity":      c.capacity,
				"running_loops": runningLoops,
			}
			if err := c.send(ctx, conn, c.topic(), "heartbeat", payload, c.nextRef()); err != nil {
				return fmt.Errorf("app heartbeat: %w", err)
			}
		}
	}
}

func (c *Client) listenLoop(ctx context.Context, conn *websocket.Conn) error {
	for {
		msg, err := c.receive(ctx, conn)
		if err != nil {
			return fmt.Errorf("listen: %w", err)
		}

		if msg.Event == "phx_reply" || msg.Event == "phx_close" {
			continue
		}

		log.Printf("Received: topic=%s event=%s", msg.Topic, msg.Event)

		if handler, ok := c.handlers[msg.Event]; ok {
			payload, _ := msg.Payload.(map[string]interface{})
			if payload == nil {
				payload = make(map[string]interface{})
			}
			go func(event string) {
				if err := handler(ctx, payload); err != nil {
					log.Printf("Handler error for %s: %v", event, err)
				}
			}(msg.Event)
		}
	}
}

func (c *Client) send(ctx context.Context, conn *websocket.Conn, topic, event string, payload interface{}, ref string) error {
	msg := PhoenixMessage{
		Topic:   topic,
		Event:   event,
		Payload: payload,
		Ref:     ref,
	}

	if topic != "phoenix" {
		msg.JoinRef = c.joinRef
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshaling message: %w", err)
	}

	return conn.Write(ctx, websocket.MessageText, data)
}

func (c *Client) receive(ctx context.Context, conn *websocket.Conn) (*PhoenixMessage, error) {
	_, data, err := conn.Read(ctx)
	if err != nil {
		return nil, err
	}

	var msg PhoenixMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		return nil, fmt.Errorf("unmarshaling message: %w", err)
	}

	return &msg, nil
}

// FormatJoinMessage creates a Phoenix channel join message (exported for testing).
func FormatJoinMessage(topic, token, name string, ref string) ([]byte, error) {
	msg := PhoenixMessage{
		Topic: topic,
		Event: "phx_join",
		Payload: map[string]interface{}{
			"token":        token,
			"name":         name,
			"display_name": name,
		},
		Ref:     ref,
		JoinRef: ref,
	}
	return json.Marshal(msg)
}

// FormatHeartbeat creates a Phoenix-level heartbeat message (exported for testing).
func FormatHeartbeat(ref string) ([]byte, error) {
	msg := PhoenixMessage{
		Topic:   "phoenix",
		Event:   "heartbeat",
		Payload: map[string]interface{}{},
		Ref:     ref,
	}
	return json.Marshal(msg)
}

// FormatAppHeartbeat creates an application-level heartbeat message (exported for testing).
func FormatAppHeartbeat(topic string, capacity, runningLoops int, ref, joinRef string) ([]byte, error) {
	msg := PhoenixMessage{
		Topic: topic,
		Event: "heartbeat",
		Payload: map[string]interface{}{
			"capacity":      capacity,
			"running_loops": runningLoops,
		},
		Ref:     ref,
		JoinRef: joinRef,
	}
	return json.Marshal(msg)
}
