// Package adapter defines the AgentAdapter interface for pluggable agent backends.
package adapter

// Process represents a running agent process.
type Process struct {
	ID        string
	SessionID string
	Workdir   string
}

// ExitResult captures the outcome of an agent run.
type ExitResult struct {
	ExitCode  int
	SessionID string
	Output    []byte
}

// AgentAdapter is the interface that each agent type (Claude Code, Codex, Aider)
// must implement. The adapter knows how to construct the CLI invocation, pass the
// task, load prompts, and collect results. It does not interpret agent output.
type AgentAdapter interface {
	// Start spawns the agent process in the given workdir with the given task.
	Start(workdir string, task string, config map[string]string) (*Process, error)

	// SendInput writes data to the agent's stdin.
	SendInput(process *Process, data []byte) error

	// Wait blocks until the agent process exits and returns the result.
	Wait(process *Process) (*ExitResult, error)

	// Kill terminates the agent process.
	Kill(process *Process) error

	// SessionID returns the unique session identifier for the process.
	SessionID(process *Process) string
}
