package adapter

import (
	"bytes"
	"regexp"
	"sync"
)

// ansiRegex matches ANSI escape sequences.
var ansiRegex = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]|\x1b\][^\x1b]*\x1b\\|\x1b\[[0-9;]*m`)

// StripANSI removes ANSI escape sequences from data.
func StripANSI(data []byte) []byte {
	return ansiRegex.ReplaceAll(data, nil)
}

// outputCollector is a concurrent-safe buffer for accumulating PTY output.
type outputCollector struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func newOutputCollector() *outputCollector {
	return &outputCollector{}
}

func (c *outputCollector) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Write(p)
}

func (c *outputCollector) Bytes() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return bytes.Clone(c.buf.Bytes())
}
