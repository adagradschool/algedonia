package loopmanager

import (
	"testing"
	"time"
)

func TestChunkFlushIntervalFromEnv(t *testing.T) {
	t.Run("defaults when unset", func(t *testing.T) {
		got := chunkFlushIntervalFromEnv(func(_ string) string { return "" })
		if got != defaultChunkFlushInterval {
			t.Fatalf("chunkFlushIntervalFromEnv() = %v, want %v", got, defaultChunkFlushInterval)
		}
	})

	t.Run("accepts valid value", func(t *testing.T) {
		got := chunkFlushIntervalFromEnv(func(_ string) string { return "16" })
		want := 16 * time.Millisecond
		if got != want {
			t.Fatalf("chunkFlushIntervalFromEnv() = %v, want %v", got, want)
		}
	})

	t.Run("rejects invalid and too small", func(t *testing.T) {
		for _, value := range []string{"abc", "0", "-4"} {
			got := chunkFlushIntervalFromEnv(func(_ string) string { return value })
			if got != defaultChunkFlushInterval {
				t.Fatalf("chunkFlushIntervalFromEnv(%q) = %v, want %v", value, got, defaultChunkFlushInterval)
			}
		}
	})
}

func TestChunkMaxSizeFromEnv(t *testing.T) {
	t.Run("defaults when unset", func(t *testing.T) {
		got := chunkMaxSizeFromEnv(func(_ string) string { return "" })
		if got != defaultChunkMaxSize {
			t.Fatalf("chunkMaxSizeFromEnv() = %v, want %v", got, defaultChunkMaxSize)
		}
	})

	t.Run("accepts valid value", func(t *testing.T) {
		got := chunkMaxSizeFromEnv(func(_ string) string { return "8192" })
		if got != 8192 {
			t.Fatalf("chunkMaxSizeFromEnv() = %v, want %v", got, 8192)
		}
	})

	t.Run("rejects invalid and too small", func(t *testing.T) {
		for _, value := range []string{"abc", "0", "128"} {
			got := chunkMaxSizeFromEnv(func(_ string) string { return value })
			if got != defaultChunkMaxSize {
				t.Fatalf("chunkMaxSizeFromEnv(%q) = %v, want %v", value, got, defaultChunkMaxSize)
			}
		}
	})
}
