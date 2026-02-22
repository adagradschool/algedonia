package adapter

import (
	"fmt"
	"sync"
)

// Registry maps agent type names to adapter factories.
type Registry struct {
	mu        sync.RWMutex
	factories map[string]func() AgentAdapter
}

// NewRegistry creates an empty adapter registry.
func NewRegistry() *Registry {
	return &Registry{
		factories: make(map[string]func() AgentAdapter),
	}
}

// Register adds an adapter factory for the given agent type.
func (r *Registry) Register(agentType string, factory func() AgentAdapter) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.factories[agentType] = factory
}

// Get returns a new adapter instance for the given agent type.
func (r *Registry) Get(agentType string) (AgentAdapter, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	factory, ok := r.factories[agentType]
	if !ok {
		return nil, fmt.Errorf("unknown agent type %q", agentType)
	}
	return factory(), nil
}

// DefaultRegistry returns a registry pre-loaded with claude_code and codex adapters.
func DefaultRegistry() *Registry {
	r := NewRegistry()
	r.Register("claude_code", func() AgentAdapter { return &ClaudeCodeAdapter{} })
	r.Register("codex", func() AgentAdapter { return &CodexAdapter{} })
	return r
}
