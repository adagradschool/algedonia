package loopmanager

import (
	"context"
	"fmt"
	"io"
	"log"
	"strings"

	"github.com/algedonia/daemon/internal/adapter"
)

// buildAdapterTask loads the role prompt and assembles the full task string.
func buildAdapterTask(promptsDir, role, taskDesc string) string {
	systemPrompt, err := adapter.LoadPrompt(promptsDir, role)
	if err != nil {
		log.Printf("Warning: could not load prompt for role %q: %v", role, err)
		systemPrompt = ""
	}

	task := taskDesc
	if systemPrompt != "" {
		task = systemPrompt + "\n\n---\n\n" + taskDesc
	}
	if role == "decompose" {
		task += "\n\nIMPORTANT: Output your DAG as JSON between these exact delimiters:\n---ALGEDONIA_DAG_BEGIN---\n<your JSON here>\n---ALGEDONIA_DAG_END---"
	}
	return task
}

// startAdapterProcess starts the adapter and attaches a PTY reader.
// On AttachPTY failure the process is killed before returning.
func (m *Manager) startAdapterProcess(ag adapter.AgentAdapter, loopID, workdir, task, model, effort, role string) (*adapter.Process, io.Reader, error) {
	proc, err := ag.Start(workdir, task, map[string]string{
		"loop_id": loopID,
		"role":    role,
		"workdir": workdir,
		"model":   strings.TrimSpace(model),
		"effort":  strings.TrimSpace(effort),
	})
	if err != nil {
		return nil, nil, fmt.Errorf("starting adapter for loop %s: %w", loopID, err)
	}

	reader, _, err := ag.AttachPTY(proc)
	if err != nil {
		ag.Kill(proc)
		return nil, nil, fmt.Errorf("attaching pty for loop %s: %w", loopID, err)
	}
	return proc, reader, nil
}

// registerAdapterLoop creates a LoopProcess and inserts it into the loop map.
func (m *Manager) registerAdapterLoop(loopID, role, workdir, promptsDir string, attempt int, ag adapter.AgentAdapter, proc *adapter.Process, chunker *Chunker, cancel context.CancelFunc, done chan struct{}) *LoopProcess {
	lp := &LoopProcess{
		LoopID:     loopID,
		Chunker:    chunker,
		Cancel:     cancel,
		Done:       done,
		adapter:    ag,
		process:    proc,
		role:       role,
		promptsDir: promptsDir,
		workdir:    workdir,
		attempt:    attempt,
	}

	m.mu.Lock()
	m.loops[loopID] = lp
	m.mu.Unlock()
	return lp
}

// waitForAdapter waits for the adapter process to exit, dispatches the result,
// and cleans up the loop.
func (m *Manager) waitForAdapter(loopID, role string, lp *LoopProcess, ag adapter.AgentAdapter, proc *adapter.Process, done chan struct{}) {
	defer close(done)
	defer func() {
		lp.mu.Lock()
		lp.stopped = true
		lpAdapter := lp.adapter
		lpProcess := lp.process
		lp.mu.Unlock()

		if err := closeAdapterProcess(lpAdapter, lpProcess); err != nil {
			log.Printf("Failed to close adapter process for loop %s: %v", loopID, err)
		}
		m.mu.Lock()
		delete(m.loops, loopID)
		delete(m.termStream, loopID)
		m.mu.Unlock()
	}()

	result, waitErr := ag.Wait(proc)
	sessionID := ag.SessionID(proc)

	if waitErr != nil {
		m.sendEvent("error", map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("agent wait error: %v", waitErr),
			"recoverable": true,
		})
		return
	}

	m.handleAdapterResult(loopID, role, lp, result, sessionID)
}

// handleAdapterResult dispatches the adapter exit result to the appropriate
// role-specific handler.
func (m *Manager) handleAdapterResult(loopID, role string, lp *LoopProcess, result *adapter.ExitResult, sessionID string) {
	switch role {
	case "decompose":
		m.handleDecomposeResult(loopID, result, sessionID)
	case "checker":
		m.handleCheckerResult(loopID, lp, result, sessionID)
	default:
		m.handleDefaultResult(loopID, result, sessionID)
	}
}

// handleDecomposeResult parses DAG output and sends a loop_result or error event.
func (m *Manager) handleDecomposeResult(loopID string, result *adapter.ExitResult, sessionID string) {
	dag, parseErr := adapter.ParseDAGOutput(result.Output)
	if parseErr != nil {
		m.sendEvent("error", map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("decompose output parse error: %v", parseErr),
			"recoverable": true,
		})
		return
	}
	m.sendEvent("loop_result", map[string]interface{}{
		"loop_id":    loopID,
		"verdict":    "pass",
		"dag":        dag,
		"session_id": sessionID,
	})
}

// handleCheckerResult builds the attempt payload with checker handoff data.
func (m *Manager) handleCheckerResult(loopID string, lp *LoopProcess, result *adapter.ExitResult, sessionID string) {
	if result.ExitCode != 0 {
		m.sendEvent("error", map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("agent exited with code %d", result.ExitCode),
			"recoverable": true,
		})
		return
	}

	lp.mu.Lock()
	lpAttempt := lp.attempt
	lp.mu.Unlock()

	expectedJSON, expectedFeedback := expectedCheckerHandoffPaths(loopID, lpAttempt)
	payload := map[string]interface{}{
		"loop_id":                        loopID,
		"exit_code":                      result.ExitCode,
		"session_id":                     sessionID,
		"expected_handoff_json_path":     expectedJSON,
		"expected_handoff_feedback_path": expectedFeedback,
		"attempt":                        lpAttempt,
	}

	verdict, feedbackPath, feedback, parseErr := loadCheckerHandoff(loopID, lpAttempt)
	if parseErr != nil {
		m.sendEvent("error", map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("checker handoff parse error: %v", parseErr),
			"recoverable": true,
		})
		payload["handoff_valid"] = false
		payload["handoff_error"] = parseErr.Error()
		payload["verdict"] = "fail"
		payload["feedback"] = "Checker did not produce required handoff JSON/markdown files."
	} else {
		payload["handoff_valid"] = true
		payload["verdict"] = verdict
		payload["feedback_path"] = feedbackPath
		payload["feedback"] = feedback
	}
	m.sendEvent("attempt_complete", payload)
}

// handleDefaultResult sends an attempt_complete or error event for non-decompose,
// non-checker roles.
func (m *Manager) handleDefaultResult(loopID string, result *adapter.ExitResult, sessionID string) {
	if result.ExitCode != 0 {
		m.sendEvent("error", map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("agent exited with code %d", result.ExitCode),
			"recoverable": true,
		})
		return
	}
	m.sendEvent("attempt_complete", map[string]interface{}{
		"loop_id":    loopID,
		"exit_code":  result.ExitCode,
		"session_id": sessionID,
	})
}
