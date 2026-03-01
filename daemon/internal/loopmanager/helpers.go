package loopmanager

import (
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
)

func payloadStr(p map[string]interface{}, key string) string {
	s, _ := p[key].(string)
	return s
}

func chunkFlushIntervalFromEnv(getenv func(string) string) time.Duration {
	raw := strings.TrimSpace(getenv("ALGEDONIA_CHUNK_FLUSH_MS"))
	if raw == "" {
		return defaultChunkFlushInterval
	}

	ms, err := strconv.Atoi(raw)
	if err != nil || ms < minChunkFlushMS {
		log.Printf(
			"Invalid ALGEDONIA_CHUNK_FLUSH_MS=%q, using default %dms",
			raw,
			defaultChunkFlushInterval/time.Millisecond,
		)
		return defaultChunkFlushInterval
	}

	return time.Duration(ms) * time.Millisecond
}

func chunkMaxSizeFromEnv(getenv func(string) string) int {
	raw := strings.TrimSpace(getenv("ALGEDONIA_CHUNK_MAX_BYTES"))
	if raw == "" {
		return defaultChunkMaxSize
	}

	size, err := strconv.Atoi(raw)
	if err != nil || size < minChunkMaxBytes {
		log.Printf(
			"Invalid ALGEDONIA_CHUNK_MAX_BYTES=%q, using default %d",
			raw,
			defaultChunkMaxSize,
		)
		return defaultChunkMaxSize
	}

	return size
}

func replayMaxBytesFromEnv(getenv func(string) string) int {
	raw := strings.TrimSpace(getenv("ALGEDONIA_TERMINAL_REPLAY_BYTES"))
	if raw == "" {
		return defaultReplayMaxBytes
	}

	size, err := strconv.Atoi(raw)
	if err != nil || size < minReplayMaxBytes {
		log.Printf(
			"Invalid ALGEDONIA_TERMINAL_REPLAY_BYTES=%q, using default %d",
			raw,
			defaultReplayMaxBytes,
		)
		return defaultReplayMaxBytes
	}

	return size
}

// sendPromptToTUI waits for warmup, types prompt text character-by-character
// (simulating keyboard input), then presses Enter.
//
// Ink-based TUI agents (Codex, Claude Code) detect rapid bulk writes as paste
// bursts and treat CR as a newline within the input rather than as submit.
// Typing one character at a time with inter-character delays avoids paste
// detection and ensures Enter is interpreted as submit.
func sendPromptToTUI(
	done <-chan struct{},
	loopID, prompt string,
	writeFn func([]byte) error,
) {
	const (
		warmup      = 1500 * time.Millisecond
		charDelay   = 5 * time.Millisecond
		settleDelay = 300 * time.Millisecond
	)

	if !waitOrDone(done, warmup) {
		return
	}

	// Type each character individually to avoid paste-burst detection.
	for _, ch := range []byte(prompt) {
		select {
		case <-done:
			return
		default:
		}
		if err := writeFn([]byte{ch}); err != nil {
			log.Printf("Failed to send prompt char to loop %s: %v", loopID, err)
			return
		}
		if !waitOrDone(done, charDelay) {
			return
		}
	}

	// Let the TUI settle after the last character.
	if !waitOrDone(done, settleDelay) {
		return
	}

	if err := writeFn([]byte("\r")); err != nil {
		log.Printf("Failed to send Enter to loop %s: %v", loopID, err)
		return
	}

	log.Printf("Prompt submitted for loop %s (%d bytes)", loopID, len(prompt))
}

// waitOrDone sleeps for d but returns early if done is closed.
// Returns true if the duration elapsed, false if done was signalled.
func waitOrDone(done <-chan struct{}, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-done:
		return false
	case <-t.C:
		return true
	}
}

func defaultCodingAgent() string {
	switch strings.TrimSpace(strings.ToLower(os.Getenv("ALGEDONIA_DEFAULT_CODING_AGENT"))) {
	case "claude_code":
		return "claude_code"
	case "codex":
		return "codex"
	default:
		return "claude_code"
	}
}

func parseAttempt(raw interface{}) int {
	switch v := raw.(type) {
	case int:
		return v
	case int32:
		return int(v)
	case int64:
		return int(v)
	case float64:
		return int(v)
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(v))
		if err == nil {
			return parsed
		}
	}
	return 1
}

func closeAdapterProcess(ag adapter.AgentAdapter, proc *adapter.Process) error {
	if ag == nil || proc == nil {
		return nil
	}
	// Adapter process cleanup hook. TUI adapters exit with Wait() and need no extra cleanup.
	return nil
}
