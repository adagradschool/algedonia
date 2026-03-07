package loopmanager

import (
	"context"
	"fmt"
	"io"
	"log"
	"strings"

	"github.com/algedonia/daemon/internal/adapter"
)

// buildAdapterTask returns the server-composed task payload verbatim.
func buildAdapterTask(taskDesc string) string {
	return taskDesc
}

// startAdapterProcess starts the adapter and attaches a PTY reader.
// On AttachPTY failure the process is killed before returning.
func (m *Manager) startAdapterProcess(ag adapter.AgentAdapter, loopID, workdir, workspaceSlug, task, model, effort, role string) (*adapter.Process, io.Reader, error) {
	proc, err := ag.Start(workdir, task, map[string]string{
		"loop_id":        loopID,
		"role":           role,
		"workdir":        workdir,
		"workspace_slug": strings.TrimSpace(workspaceSlug),
		"model":          strings.TrimSpace(model),
		"effort":         strings.TrimSpace(effort),
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
func (m *Manager) registerAdapterLoop(loopID, role, workdir, workspaceDir, workspaceSlug, ticketID string, attempt int, ag adapter.AgentAdapter, proc *adapter.Process, chunker *Chunker, cancel context.CancelFunc, done chan struct{}) *LoopProcess {
	lp := &LoopProcess{
		LoopID:        loopID,
		Chunker:       chunker,
		Cancel:        cancel,
		Done:          done,
		adapter:       ag,
		process:       proc,
		role:          role,
		workdir:       workdir,
		workspaceDir:  workspaceDir,
		workspaceSlug: workspaceSlug,
		ticketID:      ticketID,
		attempt:       attempt,
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
	scope := adapterScope(lp, role)

	if waitErr != nil {
		payload := map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("agent wait error: %v", waitErr),
			"recoverable": true,
		}
		mergeScopePayload(payload, scope)
		m.sendEvent("error", payload)
		return
	}

	m.handleAdapterResult(loopID, role, lp, result, sessionID, scope)
}

// handleAdapterResult dispatches the adapter exit result to the appropriate
// role-specific handler.
func (m *Manager) handleAdapterResult(loopID, role string, lp *LoopProcess, result *adapter.ExitResult, sessionID string, scope map[string]interface{}) {
	switch role {
	case "checker":
		m.handleCheckerResult(loopID, lp, result, sessionID, scope)
	default:
		m.handleDefaultResult(loopID, result, sessionID, scope)
	}
}

// handleCheckerResult builds the attempt payload with checker handoff data.
func (m *Manager) handleCheckerResult(loopID string, lp *LoopProcess, result *adapter.ExitResult, sessionID string, scope map[string]interface{}) {
	if result.ExitCode != 0 {
		payload := map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("agent exited with code %d", result.ExitCode),
			"recoverable": true,
		}
		mergeScopePayload(payload, scope)
		m.sendEvent("error", payload)
		return
	}

	lp.mu.Lock()
	lpAttempt := lp.attempt
	lpWorkspaceDir := lp.workspaceDir
	lp.mu.Unlock()

	expectedJSON, expectedFeedback := expectedCheckerHandoffPaths(loopID, lpAttempt, lpWorkspaceDir)
	payload := map[string]interface{}{
		"loop_id":                        loopID,
		"exit_code":                      result.ExitCode,
		"session_id":                     sessionID,
		"expected_handoff_json_path":     expectedJSON,
		"expected_handoff_feedback_path": expectedFeedback,
		"attempt":                        lpAttempt,
	}
	mergeScopePayload(payload, scope)

	verdict, feedbackPath, feedback, parseErr := loadCheckerHandoff(loopID, lpAttempt, lpWorkspaceDir)
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

// handleDefaultResult sends an attempt_complete or error event for non-checker roles.
func (m *Manager) handleDefaultResult(loopID string, result *adapter.ExitResult, sessionID string, scope map[string]interface{}) {
	if result.ExitCode != 0 {
		payload := map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("agent exited with code %d", result.ExitCode),
			"recoverable": true,
		}
		mergeScopePayload(payload, scope)
		m.sendEvent("error", payload)
		return
	}
	payload := map[string]interface{}{
		"loop_id":    loopID,
		"exit_code":  result.ExitCode,
		"session_id": sessionID,
	}
	mergeScopePayload(payload, scope)
	m.sendEvent("attempt_complete", payload)
}

func adapterScope(lp *LoopProcess, role string) map[string]interface{} {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	scope := map[string]interface{}{
		"role": role,
	}
	if strings.TrimSpace(lp.workspaceSlug) != "" {
		scope["workspace_slug"] = strings.TrimSpace(lp.workspaceSlug)
	}
	if strings.TrimSpace(lp.ticketID) != "" {
		scope["ticket_id"] = strings.TrimSpace(lp.ticketID)
	}
	return scope
}

func mergeScopePayload(payload map[string]interface{}, scope map[string]interface{}) {
	for key, value := range scope {
		payload[key] = value
	}
}
