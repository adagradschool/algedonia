package loopmanager

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
)

func TestHandleImageDropUpload(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), adapter.DefaultRegistry(), "")
	loopID := "c1c1c1c1-c1c1-41c1-81c1-c1c1c1c1c1c1"
	ticketID := "d2d2d2d2-d2d2-42d2-82d2-d2d2d2d2d2d2"
	workspaceSlug := "image-drop-ws"

	ctx := context.Background()
	if err := mgr.StartLoop(ctx, loopID, "cat", nil, "", ""); err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	defer mgr.StopLoop(loopID, "test cleanup")

	cleanupDir := terminalImageDropTargetDir(ticketID)
	defer os.RemoveAll(cleanupDir)

	payload := map[string]interface{}{
		"loop_id":        loopID,
		"workspace_slug": workspaceSlug,
		"ticket_id":      ticketID,
		"files": []interface{}{
			map[string]interface{}{
				"name": "first shot.png",
				"type": "image/png",
				"data": base64.StdEncoding.EncodeToString([]byte("first-image")),
			},
			map[string]interface{}{
				"name": "two's.webp",
				"type": "image/webp",
				"data": base64.StdEncoding.EncodeToString([]byte("second-image")),
			},
		},
	}

	if err := mgr.HandleImageDropUpload(ctx, payload); err != nil {
		t.Fatalf("HandleImageDropUpload: %v", err)
	}

	firstPath := terminalImageDropFilePath(ticketID, terminalImageDropUploadFile{
		Name: "first shot.png",
		Type: "image/png",
	}, []byte("first-image"))
	secondPath := terminalImageDropFilePath(ticketID, terminalImageDropUploadFile{
		Name: "two's.webp",
		Type: "image/webp",
	}, []byte("second-image"))
	expectedOutput := shellEscapePath(firstPath) + " " + shellEscapePath(secondPath)

	assertEventuallyEquals(t, 5*time.Second, func() string {
		return collectedTerminalOutput(&mu, events)
	}, expectedOutput)

	firstBytes, err := os.ReadFile(firstPath)
	if err != nil {
		t.Fatalf("ReadFile(first): %v", err)
	}
	if string(firstBytes) != "first-image" {
		t.Fatalf("first file contents = %q", string(firstBytes))
	}

	secondBytes, err := os.ReadFile(secondPath)
	if err != nil {
		t.Fatalf("ReadFile(second): %v", err)
	}
	if string(secondBytes) != "second-image" {
		t.Fatalf("second file contents = %q", string(secondBytes))
	}

	if !strings.HasPrefix(firstPath, filepath.Join("/tmp", "algedonia-terminal-drops")) {
		t.Fatalf("expected /tmp image drop path, got %s", firstPath)
	}
}

func TestHandleImageDropUploadRejectsUnsupported(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), adapter.DefaultRegistry(), "")

	err := mgr.HandleImageDropUpload(context.Background(), map[string]interface{}{
		"loop_id":        "e3e3e3e3-e3e3-43e3-83e3-e3e3e3e3e3e3",
		"workspace_slug": "image-drop-ws",
		"ticket_id":      "f4f4f4f4-f4f4-44f4-84f4-f4f4f4f4f4f4",
		"files": []interface{}{
			map[string]interface{}{
				"name": "notes.txt",
				"type": "text/plain",
				"data": base64.StdEncoding.EncodeToString([]byte("not-an-image")),
			},
		},
	})
	if err != nil {
		t.Fatalf("HandleImageDropUpload: %v", err)
	}

	if !hasTerminalImageDropResult(&mu, events, "error", "Drop rejected: no supported images were provided.") {
		t.Fatal("expected explicit unsupported-file result event")
	}
}

func TestHandleImageDropUploadRejectsOversize(t *testing.T) {
	t.Setenv("ALGEDONIA_TERMINAL_IMAGE_DROP_MAX_BYTES", "4")

	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), adapter.DefaultRegistry(), "")
	loopID := "a5a5a5a5-a5a5-45a5-85a5-a5a5a5a5a5a5"

	if err := mgr.StartLoop(context.Background(), loopID, "cat", nil, "", ""); err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	defer mgr.StopLoop(loopID, "test cleanup")

	err := mgr.HandleImageDropUpload(context.Background(), map[string]interface{}{
		"loop_id":        loopID,
		"workspace_slug": "image-drop-ws",
		"ticket_id":      "b6b6b6b6-b6b6-46b6-86b6-b6b6b6b6b6b6",
		"files": []interface{}{
			map[string]interface{}{
				"name": "big.png",
				"type": "image/png",
				"data": base64.StdEncoding.EncodeToString([]byte("12345")),
			},
		},
	})
	if err != nil {
		t.Fatalf("HandleImageDropUpload: %v", err)
	}

	if !hasTerminalImageDropResult(&mu, events, "error", "Dropped images exceed the 4 byte limit.") {
		t.Fatal("expected explicit oversize result event")
	}
}

func TestHandleImageDropUploadRejectsDecodeFailure(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), adapter.DefaultRegistry(), "")
	loopID := "d9d9d9d9-d9d9-49d9-89d9-d9d9d9d9d9d9"

	if err := mgr.StartLoop(context.Background(), loopID, "cat", nil, "", ""); err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	defer mgr.StopLoop(loopID, "test cleanup")

	err := mgr.HandleImageDropUpload(context.Background(), map[string]interface{}{
		"loop_id":        loopID,
		"workspace_slug": "image-drop-ws",
		"ticket_id":      "e0e0e0e0-e0e0-40e0-80e0-e0e0e0e0e0e0",
		"files": []interface{}{
			map[string]interface{}{
				"name": "broken.png",
				"type": "image/png",
				"data": "%%%not-base64%%%",
			},
		},
	})
	if err != nil {
		t.Fatalf("HandleImageDropUpload: %v", err)
	}

	if !hasTerminalImageDropResult(
		&mu,
		events,
		"error",
		"Dropped images could not be decoded.",
	) {
		t.Fatal("expected explicit decode-failure result event")
	}
}

func TestHandleImageDropUploadRejectsTmpWriteFailure(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), adapter.DefaultRegistry(), "")
	loopID := "c7c7c7c7-c7c7-47c7-87c7-c7c7c7c7c7c7"
	ticketID := "d8d8d8d8-d8d8-48d8-88d8-d8d8d8d8d8d8"
	workspaceSlug := "image-drop-write-failure"

	ctx := context.Background()
	if err := mgr.StartLoop(ctx, loopID, "cat", nil, "", ""); err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	defer mgr.StopLoop(loopID, "test cleanup")

	blockedTarget := terminalImageDropTargetDir(ticketID)
	defer os.RemoveAll(blockedTarget)

	if err := os.MkdirAll(filepath.Dir(blockedTarget), 0o755); err != nil {
		t.Fatalf("MkdirAll(parent): %v", err)
	}

	if err := os.WriteFile(blockedTarget, []byte("blocked"), 0o600); err != nil {
		t.Fatalf("WriteFile(target): %v", err)
	}

	err := mgr.HandleImageDropUpload(ctx, map[string]interface{}{
		"loop_id":        loopID,
		"workspace_slug": workspaceSlug,
		"ticket_id":      ticketID,
		"files": []interface{}{
			map[string]interface{}{
				"name": "blocked.png",
				"type": "image/png",
				"data": base64.StdEncoding.EncodeToString([]byte("png")),
			},
		},
	})
	if err != nil {
		t.Fatalf("HandleImageDropUpload: %v", err)
	}

	if !hasTerminalImageDropResult(
		&mu,
		events,
		"error",
		"Dropped images could not be written to /tmp.",
	) {
		t.Fatal("expected explicit /tmp write-failure result event")
	}
}

func TestHandleImageDropUploadRejectsTerminalInsertFailure(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), adapter.DefaultRegistry(), "")

	err := mgr.HandleImageDropUpload(context.Background(), map[string]interface{}{
		"loop_id":        "f1f1f1f1-f1f1-41f1-81f1-f1f1f1f1f1f1",
		"workspace_slug": "image-drop-ws",
		"ticket_id":      "a2a2a2a2-a2a2-42a2-82a2-a2a2a2a2a2a2",
		"files": []interface{}{
			map[string]interface{}{
				"name": "photo.png",
				"type": "image/png",
				"data": base64.StdEncoding.EncodeToString([]byte("png")),
			},
		},
	})
	if err != nil {
		t.Fatalf("HandleImageDropUpload: %v", err)
	}

	if !hasTerminalImageDropResult(
		&mu,
		events,
		"error",
		"Dropped image paths could not be inserted into the terminal.",
	) {
		t.Fatal("expected explicit terminal insert failure result event")
	}
}

func collectedTerminalOutput(mu *sync.Mutex, events []sentEvent) string {
	mu.Lock()
	defer mu.Unlock()

	var output string
	for _, event := range events {
		if event.Event != "terminal_output" {
			continue
		}

		encoded, _ := event.Payload["data"].(string)
		decoded, _ := base64.StdEncoding.DecodeString(encoded)
		output += string(decoded)
	}

	return output
}

func hasTerminalImageDropResult(mu *sync.Mutex, events []sentEvent, status, message string) bool {
	mu.Lock()
	defer mu.Unlock()

	for _, event := range events {
		if event.Event != "terminal_image_drop_result" {
			continue
		}
		if event.Payload["status"] == status && event.Payload["message"] == message {
			return true
		}
	}

	return false
}

func assertEventuallyContains(t *testing.T, timeout time.Duration, fn func() string, want string) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if strings.Contains(fn(), want) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}

	t.Fatalf("timed out waiting for %q in %q", want, fn())
}

func assertEventuallyEquals(t *testing.T, timeout time.Duration, fn func() string, want string) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if got := fn(); got == want {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}

	t.Fatalf("timed out waiting for exact %q in %q", want, fn())
}
