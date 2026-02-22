package loopmanager

import (
	"sync"
	"testing"
	"time"
)

func TestChunkerSizeFlush(t *testing.T) {
	var mu sync.Mutex
	var chunks [][]byte

	c := NewChunker(time.Hour, 10, func(data []byte) {
		mu.Lock()
		defer mu.Unlock()
		cp := make([]byte, len(data))
		copy(cp, data)
		chunks = append(chunks, cp)
	})
	defer c.Close()

	// Write 25 bytes — should produce 2 size-based flushes, leaving 5 in buffer
	data := []byte("abcdefghijklmnopqrstuvwxy")
	n, err := c.Write(data)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	if n != len(data) {
		t.Errorf("Write returned %d, want %d", n, len(data))
	}

	mu.Lock()
	if len(chunks) != 2 {
		t.Fatalf("got %d chunks, want 2", len(chunks))
	}
	if string(chunks[0]) != "abcdefghij" {
		t.Errorf("chunk[0] = %q, want %q", chunks[0], "abcdefghij")
	}
	if string(chunks[1]) != "klmnopqrst" {
		t.Errorf("chunk[1] = %q, want %q", chunks[1], "klmnopqrst")
	}
	mu.Unlock()

	// Close should flush remainder
	c.Close()

	mu.Lock()
	if len(chunks) != 3 {
		t.Fatalf("after close: got %d chunks, want 3", len(chunks))
	}
	if string(chunks[2]) != "uvwxy" {
		t.Errorf("chunk[2] = %q, want %q", chunks[2], "uvwxy")
	}
	mu.Unlock()
}

func TestChunkerTimeFlush(t *testing.T) {
	var mu sync.Mutex
	var chunks [][]byte

	c := NewChunker(50*time.Millisecond, 4096, func(data []byte) {
		mu.Lock()
		defer mu.Unlock()
		cp := make([]byte, len(data))
		copy(cp, data)
		chunks = append(chunks, cp)
	})
	defer c.Close()

	c.Write([]byte("hello"))

	// Wait for timer flush
	time.Sleep(150 * time.Millisecond)

	mu.Lock()
	if len(chunks) != 1 {
		t.Fatalf("got %d chunks, want 1", len(chunks))
	}
	if string(chunks[0]) != "hello" {
		t.Errorf("chunk = %q, want %q", chunks[0], "hello")
	}
	mu.Unlock()
}

func TestChunkerUTF8Safety(t *testing.T) {
	var mu sync.Mutex
	var chunks [][]byte

	// maxSize 5 — the 3-byte UTF-8 char "€" (0xE2 0x82 0xAC) should not be split
	c := NewChunker(time.Hour, 5, func(data []byte) {
		mu.Lock()
		defer mu.Unlock()
		cp := make([]byte, len(data))
		copy(cp, data)
		chunks = append(chunks, cp)
	})
	defer c.Close()

	// "abc€" = [0x61, 0x62, 0x63, 0xE2, 0x82, 0xAC] = 6 bytes
	// With maxSize 5, naive split would cut inside €
	// UTF-8 safe chunker should split at byte 3 ("abc"), then flush "€" on close
	c.Write([]byte("abc€"))

	mu.Lock()
	if len(chunks) != 1 {
		t.Fatalf("got %d chunks, want 1", len(chunks))
	}
	if string(chunks[0]) != "abc" {
		t.Errorf("chunk[0] = %q, want %q", chunks[0], "abc")
	}
	mu.Unlock()

	c.Close()

	mu.Lock()
	if len(chunks) != 2 {
		t.Fatalf("after close: got %d chunks, want 2", len(chunks))
	}
	if string(chunks[1]) != "€" {
		t.Errorf("chunk[1] = %q, want %q", chunks[1], "€")
	}
	mu.Unlock()
}

func TestChunkerCloseFlushesRemainder(t *testing.T) {
	var flushed []byte

	c := NewChunker(time.Hour, 4096, func(data []byte) {
		flushed = append(flushed, data...)
	})

	c.Write([]byte("leftover"))
	c.Close()

	if string(flushed) != "leftover" {
		t.Errorf("flushed = %q, want %q", flushed, "leftover")
	}
}
