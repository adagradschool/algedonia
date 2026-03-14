package loopmanager

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
)

type adapterLifecycleSpec struct {
	persistentSession       bool
	markerCompletesTurn     bool
	normalExitCompletesTurn bool
	waitErrorMessageFmt     string
	unexpectedExitFmt       string
}

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

	spec := lifecycleSpecForRole(role)

	if spec.persistentSession {
		m.waitForPersistentSession(loopID, role, lp, proc, spec)
		return
	}

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

func lifecycleSpecForRole(role string) adapterLifecycleSpec {
	switch role {
	case "planning":
		return adapterLifecycleSpec{
			persistentSession:       true,
			markerCompletesTurn:     false,
			normalExitCompletesTurn: true,
			waitErrorMessageFmt:     "planning agent wait error: %v",
			unexpectedExitFmt:       "planning agent exited unexpectedly with code %d",
		}
	case "review":
		return adapterLifecycleSpec{
			persistentSession:       true,
			markerCompletesTurn:     true,
			normalExitCompletesTurn: false,
			waitErrorMessageFmt:     "review agent wait error: %v",
			unexpectedExitFmt:       "review agent exited unexpectedly with code %d",
		}
	default:
		return adapterLifecycleSpec{}
	}
}

func (m *Manager) waitForPersistentSession(loopID, role string, lp *LoopProcess, proc *adapter.Process, spec adapterLifecycleSpec) {
	exitCh := make(chan struct {
		result *adapter.ExitResult
		err    error
	}, 1)

	go func() {
		result, err := adapter.WaitForExit(proc)
		exitCh <- struct {
			result *adapter.ExitResult
			err    error
		}{result: result, err: err}
	}()

	scope := adapterScope(lp, role)
	sessionID := proc.SessionID
	markerPath := strings.TrimSpace(proc.CompletionMarkerPath())
	var lastMarkerSeen time.Time
	var ticker *time.Ticker

	if spec.markerCompletesTurn {
		ticker = time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
	}

	for {
		select {
		case outcome := <-exitCh:
			if loopStopped(lp) {
				return
			}

			if outcome.err != nil {
				m.sendLifecycleError(loopID, scope, fmt.Sprintf(spec.waitErrorMessageFmt, outcome.err))
				return
			}

			if spec.normalExitCompletesTurn {
				m.handleAdapterResult(loopID, role, lp, outcome.result, sessionID, scope)
				return
			}

			exitCode := 0
			if outcome.result != nil {
				exitCode = outcome.result.ExitCode
			}

			payload := map[string]interface{}{
				"loop_id":     loopID,
				"message":     fmt.Sprintf(spec.unexpectedExitFmt, exitCode),
				"recoverable": true,
				"exit_code":   exitCode,
				"session_id":  sessionID,
			}
			mergeScopePayload(payload, scope)
			m.sendEvent("error", payload)
			return

		case <-markerTick(ticker):
			if spec.markerCompletesTurn {
				markerPayload, markerTime, ok := readCompletionMarkerPayload(markerPath, lastMarkerSeen)
				if !ok {
					continue
				}

				lastMarkerSeen = markerTime
				m.sendMarkerCompletion(loopID, sessionID, scope, markerPayload)
			}
		}
	}
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
	lpWorkdir := lp.workdir
	lp.mu.Unlock()

	snapshotCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	snapshotNeeded, err := worktreeHasChanges(snapshotCtx, lpWorkdir)
	if err != nil {
		payload := map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("checker snapshot commit failed: checking worktree changes: %v", err),
			"recoverable": false,
			"attempt":     lpAttempt,
		}
		mergeScopePayload(payload, scope)
		m.sendEvent("error", payload)
		return
	}

	var snapshotCommitTitle string
	if snapshotNeeded {
		snapshotCommitTitle, err = loadCheckerSnapshotCommitTitle(loopID, lpAttempt, lpWorkspaceDir)
		if err != nil {
			payload := map[string]interface{}{
				"loop_id":     loopID,
				"message":     fmt.Sprintf("checker snapshot commit failed: invalid checker commit_title: %v", err),
				"recoverable": false,
				"attempt":     lpAttempt,
			}
			mergeScopePayload(payload, scope)
			m.sendEvent("error", payload)
			return
		}
	}

	snapshotSHA, snapshotCreated, snapshotErr := snapshotCheckerCompletion(snapshotCtx, lpWorkdir, snapshotCommitTitle)
	if snapshotErr != nil {
		payload := map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("checker snapshot commit failed: %v", snapshotErr),
			"recoverable": false,
			"attempt":     lpAttempt,
		}
		mergeScopePayload(payload, scope)
		m.sendEvent("error", payload)
		return
	}

	expectedJSON, expectedFeedback := expectedCheckerHandoffPaths(loopID, lpAttempt, lpWorkspaceDir)
	payload := map[string]interface{}{
		"loop_id":                        loopID,
		"exit_code":                      result.ExitCode,
		"session_id":                     sessionID,
		"expected_handoff_json_path":     expectedJSON,
		"expected_handoff_feedback_path": expectedFeedback,
		"attempt":                        lpAttempt,
		"snapshot_commit_created":        snapshotCreated,
	}
	if snapshotCreated {
		payload["snapshot_commit_sha"] = snapshotSHA
		payload["snapshot_commit_message"] = snapshotCommitTitle
	}
	mergeScopePayload(payload, scope)

	handoff, parseErr := loadCheckerHandoff(loopID, lpAttempt, lpWorkspaceDir, false)
	if parseErr != nil {
		parseErrPayload := map[string]interface{}{
			"loop_id":     loopID,
			"message":     fmt.Sprintf("checker handoff parse error: %v", parseErr),
			"recoverable": true,
		}
		mergeScopePayload(parseErrPayload, scope)
		m.sendEvent("error", parseErrPayload)
		payload["handoff_valid"] = false
		payload["handoff_error"] = parseErr.Error()
		payload["verdict"] = "fail"
		payload["feedback"] = "Checker did not produce required handoff JSON/markdown files."
	} else {
		payload["handoff_valid"] = true
		payload["verdict"] = handoff.Verdict
		payload["feedback_path"] = handoff.FeedbackPath
		payload["feedback"] = handoff.Feedback
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

func loopStopped(lp *LoopProcess) bool {
	lp.mu.Lock()
	defer lp.mu.Unlock()
	return lp.stopped
}

func readCompletionMarkerPayload(path string, lastSeen time.Time) (map[string]interface{}, time.Time, bool) {
	if path == "" {
		return nil, time.Time{}, false
	}

	info, err := os.Stat(path)
	if err != nil {
		return nil, time.Time{}, false
	}

	modTime := info.ModTime()
	if !modTime.After(lastSeen) {
		return nil, time.Time{}, false
	}

	raw, err := os.ReadFile(path)
	if err != nil || len(raw) == 0 {
		return nil, time.Time{}, false
	}

	var payload map[string]interface{}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, time.Time{}, false
	}

	return payload, modTime, true
}

func markerTick(ticker *time.Ticker) <-chan time.Time {
	if ticker == nil {
		return nil
	}
	return ticker.C
}

func (m *Manager) sendLifecycleError(loopID string, scope map[string]interface{}, message string) {
	payload := map[string]interface{}{
		"loop_id":     loopID,
		"message":     message,
		"recoverable": true,
	}
	mergeScopePayload(payload, scope)
	m.sendEvent("error", payload)
}

func (m *Manager) sendMarkerCompletion(loopID, sessionID string, scope map[string]interface{}, markerPayload map[string]interface{}) {
	payload := map[string]interface{}{
		"loop_id":    loopID,
		"exit_code":  0,
		"session_id": sessionID,
	}

	for key, value := range markerPayload {
		payload[key] = value
	}

	mergeScopePayload(payload, scope)
	m.sendEvent("attempt_complete", payload)
}
