package terminalws

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/algedonia/daemon/internal/terminalstream"
	"nhooyr.io/websocket"
)

// mockVerifier implements TokenVerifier for tests.
type mockVerifier struct {
	err error
}

func (m *mockVerifier) Verify(_ context.Context, token, loopID string) error {
	return m.err
}

// mockTerminalManager implements TerminalManager for tests.
type mockTerminalManager struct {
	mu          sync.Mutex
	inputCalls  []inputCall
	resizeCalls []resizeCall
	streamCh    chan terminalstream.Chunk
	replay      []terminalstream.Chunk
	fromSeq     []uint64
}

type inputCall struct {
	loopID string
	data   []byte
}

type resizeCall struct {
	loopID string
	cols   uint16
	rows   uint16
}

func (m *mockTerminalManager) SubscribeTerminal(loopID string, fromSeq uint64) ([]terminalstream.Chunk, <-chan terminalstream.Chunk, func()) {
	m.mu.Lock()
	m.fromSeq = append(m.fromSeq, fromSeq)
	replay := make([]terminalstream.Chunk, len(m.replay))
	copy(replay, m.replay)
	m.mu.Unlock()

	return replay, m.streamCh, func() {}
}

func (m *mockTerminalManager) SendInput(loopID string, data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	copied := make([]byte, len(data))
	copy(copied, data)
	m.inputCalls = append(m.inputCalls, inputCall{loopID: loopID, data: copied})
	return nil
}

func (m *mockTerminalManager) ResizeLoop(loopID string, cols, rows uint16) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.resizeCalls = append(m.resizeCalls, resizeCall{loopID: loopID, cols: cols, rows: rows})
	return nil
}

func TestHandleTerminalWS_MissingParams(t *testing.T) {
	tests := []struct {
		name  string
		query string
	}{
		{"missing both", ""},
		{"missing token", "loop_id=11111111-1111-4111-8111-111111111111"},
		{"missing loop_id", "token=tok"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mgr := &mockTerminalManager{streamCh: make(chan terminalstream.Chunk)}
			srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

			handler := http.HandlerFunc(srv.handleTerminalWS)
			ts := httptest.NewServer(handler)
			defer ts.Close()

			url := ts.URL + "/terminal/ws"
			if tt.query != "" {
				url += "?" + tt.query
			}

			resp, err := http.Get(url)
			if err != nil {
				t.Fatalf("request failed: %v", err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusBadRequest {
				t.Errorf("status = %d, want %d", resp.StatusCode, http.StatusBadRequest)
			}
		})
	}
}

func TestHandleTerminalWS_TokenVerificationFailure(t *testing.T) {
	mgr := &mockTerminalManager{streamCh: make(chan terminalstream.Chunk)}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{err: fmt.Errorf("bad token")})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/terminal/ws?loop_id=11111111-1111-4111-8111-111111111111&token=bad")
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", resp.StatusCode, http.StatusUnauthorized)
	}
}

func TestHandleTerminalWS_SuccessfulConnection(t *testing.T) {
	mgr := &mockTerminalManager{streamCh: make(chan terminalstream.Chunk, 10)}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	loopID := "22222222-2222-4222-8222-222222222222"
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/terminal/ws?loop_id=" + loopID + "&token=valid"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	// Connection succeeded - close gracefully
	conn.Close(websocket.StatusNormalClosure, "done")
}

func TestHandleTerminalWS_InputFrame(t *testing.T) {
	mgr := &mockTerminalManager{streamCh: make(chan terminalstream.Chunk, 10)}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	loopID := "33333333-3333-4333-8333-333333333333"
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/terminal/ws?loop_id=" + loopID + "&token=valid"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	// Send input frame: 0x00 prefix + data
	inputData := append([]byte{frameTypeInput}, []byte("hello")...)
	if err := conn.Write(ctx, websocket.MessageBinary, inputData); err != nil {
		t.Fatalf("write failed: %v", err)
	}

	// Give server a moment to process
	time.Sleep(100 * time.Millisecond)

	mgr.mu.Lock()
	calls := mgr.inputCalls
	mgr.mu.Unlock()

	if len(calls) == 0 {
		t.Fatal("expected SendInput to be called")
	}
	if string(calls[0].data) != "hello" {
		t.Errorf("input data = %q, want %q", string(calls[0].data), "hello")
	}
	if calls[0].loopID != loopID {
		t.Errorf("loopID = %q, want %q", calls[0].loopID, loopID)
	}

	conn.Close(websocket.StatusNormalClosure, "done")
}

func TestHandleTerminalWS_ResizeFrame(t *testing.T) {
	mgr := &mockTerminalManager{streamCh: make(chan terminalstream.Chunk, 10)}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	loopID := "44444444-4444-4444-8444-444444444444"
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/terminal/ws?loop_id=" + loopID + "&token=valid"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	// Send resize frame: 0x01 prefix + JSON
	ctrl := controlMessage{Type: "resize", Cols: 120, Rows: 40}
	ctrlJSON, _ := json.Marshal(ctrl)
	resizeData := append([]byte{frameTypeControl}, ctrlJSON...)
	if err := conn.Write(ctx, websocket.MessageBinary, resizeData); err != nil {
		t.Fatalf("write failed: %v", err)
	}

	time.Sleep(100 * time.Millisecond)

	mgr.mu.Lock()
	calls := mgr.resizeCalls
	mgr.mu.Unlock()

	if len(calls) == 0 {
		t.Fatal("expected ResizeLoop to be called")
	}
	if calls[0].cols != 120 || calls[0].rows != 40 {
		t.Errorf("resize = %dx%d, want 120x40", calls[0].cols, calls[0].rows)
	}

	conn.Close(websocket.StatusNormalClosure, "done")
}

func TestHandleTerminalWS_EdgeCaseFrames(t *testing.T) {
	mgr := &mockTerminalManager{streamCh: make(chan terminalstream.Chunk, 10)}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	loopID := "55555555-5555-4555-8555-555555555555"
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/terminal/ws?loop_id=" + loopID + "&token=valid"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	// Send empty binary message (should be skipped)
	if err := conn.Write(ctx, websocket.MessageBinary, []byte{}); err != nil {
		t.Fatalf("write empty: %v", err)
	}

	// Send single-byte input frame (no data, should be skipped)
	if err := conn.Write(ctx, websocket.MessageBinary, []byte{frameTypeInput}); err != nil {
		t.Fatalf("write single-byte input: %v", err)
	}

	// Send single-byte control frame (no JSON, should be skipped)
	if err := conn.Write(ctx, websocket.MessageBinary, []byte{frameTypeControl}); err != nil {
		t.Fatalf("write single-byte control: %v", err)
	}

	// Send control frame with invalid JSON (should be skipped)
	if err := conn.Write(ctx, websocket.MessageBinary, append([]byte{frameTypeControl}, []byte("{bad json")...)); err != nil {
		t.Fatalf("write invalid control json: %v", err)
	}

	// Send control frame with non-resize type (should be ignored)
	ctrl := controlMessage{Type: "unknown_type", Cols: 80, Rows: 24}
	ctrlJSON, _ := json.Marshal(ctrl)
	if err := conn.Write(ctx, websocket.MessageBinary, append([]byte{frameTypeControl}, ctrlJSON...)); err != nil {
		t.Fatalf("write non-resize control: %v", err)
	}

	// Now send a real input frame to verify the connection still works
	if err := conn.Write(ctx, websocket.MessageBinary, append([]byte{frameTypeInput}, []byte("after-edge-cases")...)); err != nil {
		t.Fatalf("write real input: %v", err)
	}

	time.Sleep(100 * time.Millisecond)

	mgr.mu.Lock()
	inputCount := len(mgr.inputCalls)
	resizeCount := len(mgr.resizeCalls)
	mgr.mu.Unlock()

	// Only the real input frame should have been forwarded
	if inputCount != 1 {
		t.Errorf("expected 1 SendInput call, got %d", inputCount)
	}
	// No resize calls should have happened (invalid JSON + non-resize type)
	if resizeCount != 0 {
		t.Errorf("expected 0 ResizeLoop calls, got %d", resizeCount)
	}

	conn.Close(websocket.StatusNormalClosure, "done")
}

func TestHandleTerminalWS_PTYToWebSocket(t *testing.T) {
	streamCh := make(chan terminalstream.Chunk, 10)
	mgr := &mockTerminalManager{streamCh: streamCh}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/terminal/ws?loop_id=loop1&token=valid"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	// Push data through the stream channel (simulating PTY output)
	streamCh <- terminalstream.Chunk{Seq: 42, Data: []byte("output from pty")}

	// Read the frame from the WebSocket
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	if msgType != websocket.MessageBinary {
		t.Errorf("message type = %v, want Binary", msgType)
	}
	if len(payload) < 10 {
		t.Fatalf("payload too short: %d bytes", len(payload))
	}
	if payload[0] != frameTypeInput {
		t.Errorf("frame type = 0x%02x, want 0x%02x", payload[0], frameTypeInput)
	}
	seq := binary.BigEndian.Uint64(payload[1:9])
	if seq != 42 {
		t.Errorf("seq = %d, want 42", seq)
	}
	if string(payload[9:]) != "output from pty" {
		t.Errorf("payload data = %q, want %q", string(payload[9:]), "output from pty")
	}

	conn.Close(websocket.StatusNormalClosure, "done")
}

func TestHandleTerminalWS_ReplayFromSeq(t *testing.T) {
	streamCh := make(chan terminalstream.Chunk, 10)
	mgr := &mockTerminalManager{
		streamCh: streamCh,
		replay: []terminalstream.Chunk{
			{Seq: 7, Data: []byte("replay")},
		},
	}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/terminal/ws?loop_id=loop1&token=valid&from_seq=7"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	if msgType != websocket.MessageBinary {
		t.Errorf("message type = %v, want Binary", msgType)
	}
	if len(payload) < 10 {
		t.Fatalf("payload too short: %d bytes", len(payload))
	}
	if payload[0] != frameTypeInput {
		t.Errorf("frame type = 0x%02x, want 0x%02x", payload[0], frameTypeInput)
	}
	if seq := binary.BigEndian.Uint64(payload[1:9]); seq != 7 {
		t.Fatalf("seq = %d, want 7", seq)
	}
	if got := string(payload[9:]); got != "replay" {
		t.Fatalf("payload data = %q, want %q", got, "replay")
	}

	mgr.mu.Lock()
	defer mgr.mu.Unlock()
	if len(mgr.fromSeq) == 0 || mgr.fromSeq[0] != 7 {
		t.Fatalf("fromSeq calls = %v, want first call 7", mgr.fromSeq)
	}
}

func TestHandleTerminalWS_InvalidFromSeqFallsBackToZero(t *testing.T) {
	streamCh := make(chan terminalstream.Chunk, 1)
	mgr := &mockTerminalManager{streamCh: streamCh}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/terminal/ws?loop_id=loop1&token=valid&from_seq=bad"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	mgr.mu.Lock()
	defer mgr.mu.Unlock()
	if len(mgr.fromSeq) == 0 || mgr.fromSeq[0] != 0 {
		t.Fatalf("fromSeq calls = %v, want first call 0", mgr.fromSeq)
	}
}

func TestHandleTerminalWS_ClosesSocketWhenStreamEnds(t *testing.T) {
	streamCh := make(chan terminalstream.Chunk, 1)
	mgr := &mockTerminalManager{streamCh: streamCh}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	handler := http.HandlerFunc(srv.handleTerminalWS)
	ts := httptest.NewServer(handler)
	defer ts.Close()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/terminal/ws?loop_id=loop1&token=valid"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer conn.CloseNow()

	close(streamCh)

	_, _, err = conn.Read(ctx)
	if err == nil {
		t.Fatal("expected websocket read to fail after stream close")
	}
}

func TestServerStartAndShutdown(t *testing.T) {
	mgr := &mockTerminalManager{streamCh: make(chan terminalstream.Chunk)}
	srv := NewServer("127.0.0.1:0", mgr, &mockVerifier{})

	ctx, cancel := context.WithCancel(context.Background())

	if err := srv.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	// Cancel triggers graceful shutdown
	cancel()

	// Give shutdown a moment
	time.Sleep(200 * time.Millisecond)
}
