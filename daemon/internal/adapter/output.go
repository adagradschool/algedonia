package adapter

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"sync"
)

const (
	dagBeginDelimiter = "---ALGEDONIA_DAG_BEGIN---"
	dagEndDelimiter   = "---ALGEDONIA_DAG_END---"
)

// DAGOutput represents the structured output from a decompose agent.
type DAGOutput struct {
	Loops        []LoopDefinition `json:"loops"`
	Dependencies []Dependency     `json:"dependencies"`
}

// LoopDefinition describes a single loop in the DAG.
type LoopDefinition struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Rubric      string   `json:"rubric"`
	PathHints   []string `json:"path_hints"`
}

// Dependency represents an edge in the DAG.
type Dependency struct {
	Upstream   string `json:"upstream"`
	Downstream string `json:"downstream"`
}

// ansiRegex matches ANSI escape sequences.
var ansiRegex = regexp.MustCompile(`\x1b\[[0-9;]*[a-zA-Z]|\x1b\][^\x1b]*\x1b\\|\x1b\[[0-9;]*m`)

// StripANSI removes ANSI escape sequences from data.
func StripANSI(data []byte) []byte {
	return ansiRegex.ReplaceAll(data, nil)
}

// ParseDAGOutput extracts and parses JSON between DAG delimiters in raw agent output.
func ParseDAGOutput(raw []byte) (*DAGOutput, error) {
	cleaned := StripANSI(raw)

	beginIdx := bytes.Index(cleaned, []byte(dagBeginDelimiter))
	if beginIdx == -1 {
		return nil, fmt.Errorf("missing DAG begin delimiter %q in output", dagBeginDelimiter)
	}
	endIdx := bytes.Index(cleaned, []byte(dagEndDelimiter))
	if endIdx == -1 {
		return nil, fmt.Errorf("missing DAG end delimiter %q in output", dagEndDelimiter)
	}
	if endIdx <= beginIdx {
		return nil, fmt.Errorf("DAG end delimiter appears before begin delimiter")
	}

	jsonData := cleaned[beginIdx+len(dagBeginDelimiter) : endIdx]
	jsonData = bytes.TrimSpace(jsonData)

	var dag DAGOutput
	if err := json.Unmarshal(jsonData, &dag); err != nil {
		return nil, fmt.Errorf("parsing DAG JSON: %w", err)
	}

	if len(dag.Loops) == 0 {
		return nil, fmt.Errorf("DAG output contains no loops")
	}

	for i, l := range dag.Loops {
		if l.ID == "" {
			return nil, fmt.Errorf("loop at index %d has empty ID", i)
		}
		if l.Title == "" {
			return nil, fmt.Errorf("loop %q has empty title", l.ID)
		}
	}

	return &dag, nil
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
