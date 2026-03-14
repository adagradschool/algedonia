package loopmanager

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/algedonia/daemon/internal/repo"
)

func TestHandleRunWorkspaceScriptExecutesInTicketWorktreeAndEmitsDedicatedEvents(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")
	configureScopedWorktree(t, mgr, "scope")

	runID := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	ticketID := "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

	err := mgr.HandleRunWorkspaceScript(context.Background(), map[string]interface{}{
		"run_id":              runID,
		"workspace_slug":      "scope",
		"ticket_id":           ticketID,
		"worktree_run_script": `printf '%s\n%s\n' "$PWD" "$BASH_VERSION" > manual-run.txt; echo stdout line; echo stderr line >&2`,
	})
	if err != nil {
		t.Fatalf("HandleRunWorkspaceScript: %v", err)
	}

	workdir := filepath.Join(mgr.workdirForWorkspace("scope"), "worktrees", repo.TicketPrefix(ticketID))
	contents, err := os.ReadFile(filepath.Join(workdir, "manual-run.txt"))
	if err != nil {
		t.Fatalf("read manual-run.txt: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(contents)), "\n")
	if len(lines) < 2 {
		t.Fatalf("expected workdir and bash version, got %q", string(contents))
	}
	if lines[0] != workdir {
		t.Fatalf("script ran in %q, want %q", lines[0], workdir)
	}
	if strings.TrimSpace(lines[1]) == "" {
		t.Fatal("expected bash version output to confirm bash execution")
	}

	mu.Lock()
	defer mu.Unlock()

	var sawStarted bool
	var completionStatus string
	var completionExitCode int
	var output strings.Builder

	for _, event := range events {
		switch event.Event {
		case "manual_run_started":
			if event.Payload["run_id"] == runID {
				sawStarted = true
			}
		case "manual_run_output":
			if event.Payload["run_id"] != runID {
				continue
			}
			encoded, _ := event.Payload["data"].(string)
			decoded, _ := base64.StdEncoding.DecodeString(encoded)
			output.Write(decoded)
		case "manual_run_complete":
			if event.Payload["run_id"] != runID {
				continue
			}
			completionStatus, _ = event.Payload["status"].(string)
			completionExitCode, _ = event.Payload["exit_code"].(int)
		case "terminal_output":
			t.Fatalf("manual run leaked output into terminal_output: %#v", event.Payload)
		}
	}

	if !sawStarted {
		t.Fatal("expected manual_run_started event")
	}
	if completionStatus != "succeeded" {
		t.Fatalf("completion status = %q, want succeeded", completionStatus)
	}
	if completionExitCode != 0 {
		t.Fatalf("completion exit_code = %d, want 0", completionExitCode)
	}

	outputText := output.String()
	if !strings.Contains(outputText, "stdout line") {
		t.Fatalf("output missing stdout line: %q", outputText)
	}
	if !strings.Contains(outputText, "stderr line") {
		t.Fatalf("output missing stderr line: %q", outputText)
	}
}

func TestHandleRunWorkspaceScriptRejectsDuplicate(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent
	started := make(chan struct{}, 1)

	sendFunc := func(event string, payload map[string]interface{}) error {
		mu.Lock()
		events = append(events, sentEvent{Event: event, Payload: payload})
		mu.Unlock()

		if event == "manual_run_started" {
			select {
			case started <- struct{}{}:
			default:
			}
		}

		return nil
	}

	mgr := NewManager(sendFunc, nil, "")
	configureScopedWorktree(t, mgr, "scope")

	firstDone := make(chan error, 1)
	go func() {
		firstDone <- mgr.HandleRunWorkspaceScript(context.Background(), map[string]interface{}{
			"run_id":              "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
			"workspace_slug":      "scope",
			"ticket_id":           "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
			"worktree_run_script": "echo first run; sleep 1",
		})
	}()

	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for first manual run to start")
	}

	err := mgr.HandleRunWorkspaceScript(context.Background(), map[string]interface{}{
		"run_id":              "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
		"workspace_slug":      "scope",
		"ticket_id":           "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
		"worktree_run_script": "echo duplicate run",
	})
	if err == nil || !strings.Contains(err.Error(), "manual run already active") {
		t.Fatalf("expected duplicate guard error, got %v", err)
	}

	select {
	case err = <-firstDone:
		if err != nil {
			t.Fatalf("first manual run returned error: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for first manual run to finish")
	}

	mu.Lock()
	defer mu.Unlock()

	var sawRejected bool
	for _, event := range events {
		if event.Event == "manual_run_complete" &&
			event.Payload["run_id"] == "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" &&
			event.Payload["status"] == "rejected" {
			sawRejected = true
		}
	}

	if !sawRejected {
		t.Fatal("expected rejected completion event for duplicate manual run")
	}
}

func TestHandleRunWorkspaceScriptReportsFailures(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")
	configureScopedWorktree(t, mgr, "scope")

	runID := "ffffffff-ffff-4fff-8fff-ffffffffffff"
	err := mgr.HandleRunWorkspaceScript(context.Background(), map[string]interface{}{
		"run_id":              runID,
		"workspace_slug":      "scope",
		"ticket_id":           "12121212-1212-4212-8212-121212121212",
		"worktree_run_script": "echo failed run >&2; exit 7",
	})
	if err != nil {
		t.Fatalf("HandleRunWorkspaceScript: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()

	for _, event := range events {
		if event.Event == "manual_run_complete" && event.Payload["run_id"] == runID {
			if event.Payload["status"] != "failed" {
				t.Fatalf("completion status = %v, want failed", event.Payload["status"])
			}
			if event.Payload["exit_code"] != 7 {
				t.Fatalf("completion exit_code = %v, want 7", event.Payload["exit_code"])
			}
			return
		}
	}

	t.Fatal("expected manual_run_complete event for failed run")
}
