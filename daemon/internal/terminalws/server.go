package terminalws

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"time"

	"github.com/algedonia/daemon/internal/loopmanager"
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

// Server exposes loop PTY streams over a direct WebSocket.
type Server struct {
	listenAddr string
	manager    *loopmanager.Manager
	verifier   TokenVerifier
	httpServer *http.Server
}

func NewServer(listenAddr string, manager *loopmanager.Manager, verifier TokenVerifier) *Server {
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

	streamCh, unsubscribe := s.manager.SubscribeTerminal(loopID)
	defer unsubscribe()

	writeCtx, cancelWrite := context.WithCancel(r.Context())
	defer cancelWrite()

	// PTY -> WebSocket
	go func() {
		for {
			select {
			case <-writeCtx.Done():
				return
			case chunk, ok := <-streamCh:
				if !ok {
					return
				}
				payload := make([]byte, 1+len(chunk))
				payload[0] = frameTypeInput
				copy(payload[1:], chunk)
				if err := conn.Write(writeCtx, websocket.MessageBinary, payload); err != nil {
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
