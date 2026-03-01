package terminalws

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/algedonia/daemon/internal/terminalstream"
	"nhooyr.io/websocket"
)

const (
	frameTypeInput   byte = 0x00
	frameTypeControl byte = 0x01

	defaultVerifyTimeout = 5 * time.Second
)

type controlMessage struct {
	Type string `json:"type"`
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}

// TokenVerifier validates short-lived terminal access tokens issued by the server.
type TokenVerifier interface {
	Verify(ctx context.Context, token, loopID string) error
}

// TerminalManager provides access to loop PTY streams.
type TerminalManager interface {
	SubscribeTerminal(loopID string, fromSeq uint64) ([]terminalstream.Chunk, <-chan terminalstream.Chunk, func())
	SendInput(loopID string, data []byte) error
	ResizeLoop(loopID string, cols, rows uint16) error
}

// Server exposes loop PTY streams over a direct WebSocket.
type Server struct {
	listenAddr string
	manager    TerminalManager
	verifier   TokenVerifier
	httpServer *http.Server
}

func NewServer(listenAddr string, manager TerminalManager, verifier TokenVerifier) *Server {
	return &Server{
		listenAddr: listenAddr,
		manager:    manager,
		verifier:   verifier,
	}
}

func (s *Server) Start(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/terminal/ws", s.handleTerminalWS)

	s.httpServer = &http.Server{
		Addr:              s.listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	ln, err := net.Listen("tcp", s.listenAddr)
	if err != nil {
		return fmt.Errorf("listen terminal ws on %s: %w", s.listenAddr, err)
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = s.httpServer.Shutdown(shutdownCtx)
	}()

	go func() {
		if err := s.httpServer.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("terminal ws server stopped with error: %v", err)
		}
	}()

	log.Printf("Terminal WS listening on ws://%s/terminal/ws", s.listenAddr)
	return nil
}

func (s *Server) handleTerminalWS(w http.ResponseWriter, r *http.Request) {
	loopID := r.URL.Query().Get("loop_id")
	token := r.URL.Query().Get("token")
	if loopID == "" || token == "" {
		http.Error(w, "missing loop_id/token", http.StatusBadRequest)
		return
	}

	verifyCtx, cancelVerify := context.WithTimeout(r.Context(), defaultVerifyTimeout)
	defer cancelVerify()
	if err := s.verifier.Verify(verifyCtx, token, loopID); err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
		return
	}
	defer conn.CloseNow()

	fromSeq := uint64(0)
	if raw := r.URL.Query().Get("from_seq"); raw != "" {
		if parsed, err := strconv.ParseUint(raw, 10, 64); err == nil {
			fromSeq = parsed
		}
	}

	replay, streamCh, unsubscribe := s.manager.SubscribeTerminal(loopID, fromSeq)
	defer unsubscribe()

	writeCtx, cancelWrite := context.WithCancel(r.Context())
	defer cancelWrite()

	writeChunk := func(chunk terminalstream.Chunk) error {
		payload := make([]byte, 1+8+len(chunk.Data))
		payload[0] = frameTypeInput
		binary.BigEndian.PutUint64(payload[1:9], chunk.Seq)
		copy(payload[9:], chunk.Data)
		return conn.Write(writeCtx, websocket.MessageBinary, payload)
	}

	for _, chunk := range replay {
		if err := writeChunk(chunk); err != nil {
			return
		}
	}

	// PTY -> WebSocket
	go func() {
		for {
			select {
			case <-writeCtx.Done():
				return
			case chunk, ok := <-streamCh:
				if !ok {
					_ = conn.Close(websocket.StatusPolicyViolation, "terminal stream reset")
					cancelWrite()
					return
				}
				if err := writeChunk(chunk); err != nil {
					cancelWrite()
					return
				}
			}
		}
	}()

	// WebSocket -> PTY
	for {
		msgType, payload, err := conn.Read(r.Context())
		if err != nil {
			return
		}
		if msgType != websocket.MessageBinary {
			continue
		}
		if len(payload) == 0 {
			continue
		}

		switch payload[0] {
		case frameTypeInput:
			if len(payload) == 1 {
				continue
			}
			_ = s.manager.SendInput(loopID, payload[1:])
		case frameTypeControl:
			if len(payload) == 1 {
				continue
			}
			var ctrl controlMessage
			if err := json.Unmarshal(payload[1:], &ctrl); err != nil {
				continue
			}
			if ctrl.Type == "resize" {
				_ = s.manager.ResizeLoop(loopID, ctrl.Cols, ctrl.Rows)
			}
		}
	}
}
