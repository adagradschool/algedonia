package loopmanager

import (
	"sync"
	"time"
	"unicode/utf8"
)

// Chunker buffers output and flushes on time or size threshold.
// It is UTF-8 safe: it avoids splitting multi-byte characters at chunk boundaries.
type Chunker struct {
	mu            sync.Mutex
	buf           []byte
	maxSize       int
	flushInterval time.Duration
	flushFunc     func([]byte)
	timer         *time.Timer
	closed        bool
}

// NewChunker creates a chunker that flushes when buf reaches maxSize bytes
// or after flushInterval elapses, whichever comes first.
func NewChunker(flushInterval time.Duration, maxSize int, flushFunc func([]byte)) *Chunker {
	c := &Chunker{
		maxSize:       maxSize,
		flushInterval: flushInterval,
		flushFunc:     flushFunc,
	}
	c.timer = time.AfterFunc(flushInterval, c.timerFlush)
	c.timer.Stop()
	return c
}

// Write implements io.Writer. It accumulates data and auto-flushes
// when the buffer exceeds maxSize.
func (c *Chunker) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return 0, nil
	}

	c.buf = append(c.buf, p...)

	for len(c.buf) >= c.maxSize {
		c.flushUpToLocked(c.maxSize)
	}

	// Reset timer if there's pending data
	if len(c.buf) > 0 {
		c.timer.Reset(c.flushInterval)
	}

	return len(p), nil
}

// Flush forces a flush of all buffered data.
func (c *Chunker) Flush() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.flushAllLocked()
}

// Close performs a final flush and stops the timer.
func (c *Chunker) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.closed = true
	c.timer.Stop()
	c.flushAllLocked()
}

func (c *Chunker) timerFlush() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.flushAllLocked()
}

func (c *Chunker) flushAllLocked() {
	if len(c.buf) == 0 {
		return
	}
	data := make([]byte, len(c.buf))
	copy(data, c.buf)
	c.buf = c.buf[:0]
	c.flushFunc(data)
}

// flushUpToLocked flushes up to n bytes, backing off to avoid splitting
// a multi-byte UTF-8 character at the boundary.
func (c *Chunker) flushUpToLocked(n int) {
	if len(c.buf) == 0 {
		return
	}
	if n > len(c.buf) {
		n = len(c.buf)
	}

	// Walk back from the cut point to find a safe UTF-8 boundary.
	// Look for a leading byte (non-continuation) near the end and check
	// if the character it starts is complete within the slice.
	cutPoint := n
	for cutPoint > 0 && !utf8.RuneStart(c.buf[cutPoint-1]) {
		// c.buf[cutPoint-1] is a continuation byte (10xxxxxx), back up
		cutPoint--
	}
	// Now cutPoint-1 is either a leading byte or we hit 0.
	// Check if the rune starting at cutPoint-1 fits entirely in [:n].
	if cutPoint > 0 {
		_, size := utf8.DecodeRune(c.buf[cutPoint-1:])
		if cutPoint-1+size > n {
			// Rune extends past n — exclude it
			cutPoint--
		}
	}

	if cutPoint == 0 {
		// All bytes are part of one incomplete sequence; flush everything
		cutPoint = n
	}

	data := make([]byte, cutPoint)
	copy(data, c.buf[:cutPoint])
	c.buf = c.buf[cutPoint:]
	c.flushFunc(data)
}
