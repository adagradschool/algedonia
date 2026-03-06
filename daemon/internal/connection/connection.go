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

// JoinCallback is called after a successful channel join with the join reply response.
type JoinCallback func(ctx context.Context, response map[string]interface{})

// Client manages a persistent connection to the Phoenix server.
type Client struct {
	serverURL string
	token     string
	name      string
	capacity  int
	ref       atomic.Int64
	joinRef   string

	connMu  sync.RWMutex
	conn    *websocket.Conn
	connCtx context.Context

	// writeMu guards direct writes before the write loop starts (join handshake).
	writeMu sync.Mutex

	// dataCh carries normal messages (terminal output, events).
	// heartbeatCh carries heartbeats on a separate channel so they
	// are never blocked behind a burst of terminal output.
	dataCh      chan pendingWrite
	heartbeatCh chan pendingWrite

	handlers map[string]func(ctx context.Context, payload map[string]interface{}) error

	runningLoopsFn func() int
	onJoin         JoinCallback
}

type pendingWrite struct {
	data  []byte
	errCh chan error
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

// OnJoin registers a callback invoked after a successful channel join.
func (c *Client) OnJoin(cb JoinCallback) {
	c.onJoin = cb
}

// SendEvent sends an event to the server on the daemon topic. Thread-safe.
func (c *Client) SendEvent(event string, payload map[string]interface{}) error {
	c.connMu.RLock()
	ctx := c.connCtx
	c.connMu.RUnlock()

	if ctx == nil {
		return fmt.Errorf("not connected")
	}

	return c.sendData(ctx, c.topic(), event, payload, c.nextRef())
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

	// Join channel (direct write, before write loop starts)
	c.joinRef = c.nextRef()
	joinPayload := map[string]interface{}{
		"display_name": c.name,
	}

	if err := c.directWrite(ctx, conn, c.topic(), "phx_join", joinPayload, c.joinRef); err != nil {
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
		if ok && c.onJoin != nil {
			if resp, ok := payload["response"].(map[string]interface{}); ok {
				go c.onJoin(ctx, resp)
			}
		}
	}

	log.Printf("Connected and joined as %q", c.name)

	// Start the two-channel write loop: heartbeats always drain first.
	c.dataCh = make(chan pendingWrite, 256)
	c.heartbeatCh = make(chan pendingWrite, 16)
	defer func() {
		c.dataCh = nil
		c.heartbeatCh = nil
	}()

	errCh := make(chan error, 4)

	go func() {
		errCh <- c.writeLoop(ctx, conn)
	}()

	// Phoenix-level heartbeat (keeps WebSocket alive)
	go func() {
		errCh <- c.phoenixHeartbeatLoop(ctx)
	}()

	// App-level heartbeat (reports daemon metrics)
	go func() {
		errCh <- c.appHeartbeatLoop(ctx)
	}()

	// Listen for server pushes
	go func() {
		errCh <- c.listenLoop(ctx, conn)
	}()

	select {
	case <-ctx.Done():
		// Send leave message
		_ = c.directWrite(ctx, conn, c.topic(), "phx_leave", map[string]interface{}{}, c.nextRef())
		conn.Close(websocket.StatusNormalClosure, "shutdown")
		return nil
	case err := <-errCh:
		return err
	}
}

// writeLoop is the sole goroutine that writes to the WebSocket.
// It always drains heartbeatCh before processing dataCh, ensuring
// heartbeats are never starved by terminal output bursts.
func (c *Client) writeLoop(ctx context.Context, conn *websocket.Conn) error {
	for {
		// Priority: always drain heartbeats first.
		select {
		case <-ctx.Done():
			return nil
		case hw := <-c.heartbeatCh:
			hw.errCh <- conn.Write(ctx, websocket.MessageText, hw.data)
			continue
		default:
		}

		// No heartbeats pending — wait for either channel.
		select {
		case <-ctx.Done():
			return nil
		case hw := <-c.heartbeatCh:
			hw.errCh <- conn.Write(ctx, websocket.MessageText, hw.data)
		case dw := <-c.dataCh:
			dw.errCh <- conn.Write(ctx, websocket.MessageText, dw.data)
		}
	}
}

// marshalMsg builds the wire-format JSON for a Phoenix message.
func (c *Client) marshalMsg(topic, event string, payload interface{}, ref string) ([]byte, error) {
	msg := PhoenixMessage{
		Topic:   topic,
		Event:   event,
		Payload: payload,
		Ref:     ref,
	}
	if topic != "phoenix" {
		msg.JoinRef = c.joinRef
	}
	return json.Marshal(msg)
}

// directWrite writes to the WebSocket directly, bypassing the write loop.
// Used only during the join handshake before the write loop is started.
func (c *Client) directWrite(ctx context.Context, conn *websocket.Conn, topic, event string, payload interface{}, ref string) error {
	data, err := c.marshalMsg(topic, event, payload, ref)
	if err != nil {
		return fmt.Errorf("marshaling message: %w", err)
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	return conn.Write(ctx, websocket.MessageText, data)
}

// sendHeartbeat enqueues a message on the heartbeat channel (high priority).
func (c *Client) sendHeartbeat(ctx context.Context, topic, event string, payload interface{}, ref string) error {
	data, err := c.marshalMsg(topic, event, payload, ref)
	if err != nil {
		return fmt.Errorf("marshaling message: %w", err)
	}
	ch := c.heartbeatCh
	if ch == nil {
		return fmt.Errorf("not connected")
	}
	pw := pendingWrite{data: data, errCh: make(chan error, 1)}
	select {
	case ch <- pw:
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case err := <-pw.errCh:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// sendData enqueues a message on the data channel (normal priority).
func (c *Client) sendData(ctx context.Context, topic, event string, payload interface{}, ref string) error {
	data, err := c.marshalMsg(topic, event, payload, ref)
	if err != nil {
		return fmt.Errorf("marshaling message: %w", err)
	}
	ch := c.dataCh
	if ch == nil {
		return fmt.Errorf("not connected")
	}
	pw := pendingWrite{data: data, errCh: make(chan error, 1)}
	select {
	case ch <- pw:
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case err := <-pw.errCh:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (c *Client) phoenixHeartbeatLoop(ctx context.Context) error {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if err := c.sendHeartbeat(ctx, "phoenix", "heartbeat", map[string]interface{}{}, c.nextRef()); err != nil {
				return fmt.Errorf("phoenix heartbeat: %w", err)
			}
		}
	}
}

func (c *Client) appHeartbeatLoop(ctx context.Context) error {
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
			if err := c.sendHeartbeat(ctx, c.topic(), "heartbeat", payload, c.nextRef()); err != nil {
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
