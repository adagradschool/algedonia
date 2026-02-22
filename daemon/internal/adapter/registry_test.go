package adapter

import (
	"testing"
)

func TestRegistryRegisterAndGet(t *testing.T) {
	r := NewRegistry()

	called := false
	r.Register("test_agent", func() AgentAdapter {
		called = true
		return &ClaudeCodeAdapter{}
	})

	a, err := r.Get("test_agent")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !called {
		t.Error("factory was not called")
	}
	if a == nil {
		t.Error("adapter is nil")
	}
}

func TestRegistryGetUnknown(t *testing.T) {
	r := NewRegistry()

	_, err := r.Get("nonexistent")
	if err == nil {
		t.Fatal("expected error for unknown agent type")
	}
}

func TestDefaultRegistryHasBothAdapters(t *testing.T) {
	r := DefaultRegistry()

	claude, err := r.Get("claude_code")
	if err != nil {
		t.Fatalf("Get(claude_code): %v", err)
	}
	if _, ok := claude.(*ClaudeCodeAdapter); !ok {
		t.Errorf("claude_code adapter type = %T, want *ClaudeCodeAdapter", claude)
	}

	codex, err := r.Get("codex")
	if err != nil {
		t.Fatalf("Get(codex): %v", err)
	}
	if _, ok := codex.(*CodexAdapter); !ok {
		t.Errorf("codex adapter type = %T, want *CodexAdapter", codex)
	}
}
