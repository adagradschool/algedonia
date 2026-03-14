package loopmanager

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
)

func TestCheckerSnapshotCreatesSnapshotCommitOnFail(t *testing.T) {
	loopID := "abababab-abab-4bab-8bab-abababababab"
	attempt := 2
	commitTitle := "checker: fail snapshot captures dirty tree"
	workspaceDir, workdir := setupCheckerSnapshotRepo(t, loopID, attempt, "fail", commitTitle)

	if err := os.WriteFile(filepath.Join(workdir, "feature.txt"), []byte("change\n"), 0o644); err != nil {
		t.Fatalf("write feature file: %v", err)
	}

	before := gitCommitCount(t, workdir)

	var mu sync.Mutex
	var events []sentEvent
	var headAtAttemptComplete string

	mgr := NewManager(func(event string, payload map[string]interface{}) error {
		if event == "attempt_complete" {
			headAtAttemptComplete = gitOutput(t, workdir, "rev-parse", "HEAD")
		}
		mu.Lock()
		events = append(events, sentEvent{Event: event, Payload: payload})
		mu.Unlock()
		return nil
	}, nil, "")

	lp := &LoopProcess{
		workdir:      workdir,
		workspaceDir: workspaceDir,
		attempt:      attempt,
	}
	scope := map[string]interface{}{
		"role":           "checker",
		"workspace_slug": "scope",
		"ticket_id":      "11111111-1111-4111-8111-111111111111",
	}

	mgr.handleCheckerResult(loopID, lp, &adapter.ExitResult{ExitCode: 0}, "sess-1", scope)

	after := gitCommitCount(t, workdir)
	if after != before+1 {
		t.Fatalf("commit count = %d, want %d", after, before+1)
	}

	commitMsg := gitOutput(t, workdir, "log", "-1", "--pretty=%B")
	if commitMsg != commitTitle {
		t.Fatalf("snapshot commit message = %q, want %q", commitMsg, commitTitle)
	}

	event := findEventByName(t, events, "attempt_complete")
	if event.Payload["snapshot_commit_created"] != true {
		t.Fatalf("snapshot_commit_created = %v, want true", event.Payload["snapshot_commit_created"])
	}

	snapshotSHA, _ := event.Payload["snapshot_commit_sha"].(string)
	if strings.TrimSpace(snapshotSHA) == "" {
		t.Fatal("snapshot_commit_sha is empty")
	}

	headNow := gitOutput(t, workdir, "rev-parse", "HEAD")
	if snapshotSHA != headNow {
		t.Fatalf("snapshot_commit_sha = %s, HEAD = %s", snapshotSHA, headNow)
	}
	if snapshotSHA != headAtAttemptComplete {
		t.Fatalf("HEAD at attempt_complete = %s, want %s", headAtAttemptComplete, snapshotSHA)
	}
	if event.Payload["snapshot_commit_message"] != commitTitle {
		t.Fatalf("snapshot_commit_message = %v, want %q", event.Payload["snapshot_commit_message"], commitTitle)
	}
}

func TestCheckerSnapshotCreatesSnapshotCommitOnPass(t *testing.T) {
	loopID := "bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc"
	attempt := 1
	commitTitle := "checker: pass snapshot records validated changes"
	workspaceDir, workdir := setupCheckerSnapshotRepo(t, loopID, attempt, "pass", commitTitle)

	if err := os.WriteFile(filepath.Join(workdir, "pass.txt"), []byte("change\n"), 0o644); err != nil {
		t.Fatalf("write pass file: %v", err)
	}

	before := gitCommitCount(t, workdir)

	var mu sync.Mutex
	var events []sentEvent
	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	lp := &LoopProcess{
		workdir:      workdir,
		workspaceDir: workspaceDir,
		attempt:      attempt,
	}
	scope := map[string]interface{}{
		"role":           "checker",
		"workspace_slug": "scope",
		"ticket_id":      "12121212-1212-4212-8212-121212121212",
	}

	mgr.handleCheckerResult(loopID, lp, &adapter.ExitResult{ExitCode: 0}, "sess-pass", scope)

	after := gitCommitCount(t, workdir)
	if after != before+1 {
		t.Fatalf("commit count = %d, want %d", after, before+1)
	}

	commitMsg := gitOutput(t, workdir, "log", "-1", "--pretty=%B")
	if commitMsg != commitTitle {
		t.Fatalf("snapshot commit message = %q, want %q", commitMsg, commitTitle)
	}

	event := findEventByName(t, events, "attempt_complete")
	if event.Payload["snapshot_commit_created"] != true {
		t.Fatalf("snapshot_commit_created = %v, want true", event.Payload["snapshot_commit_created"])
	}
	if event.Payload["snapshot_commit_message"] != commitTitle {
		t.Fatalf("snapshot_commit_message = %v, want %q", event.Payload["snapshot_commit_message"], commitTitle)
	}
	if event.Payload["verdict"] != "pass" {
		t.Fatalf("verdict = %v, want pass", event.Payload["verdict"])
	}
}

func TestCheckerSnapshotSkipsCommitWhenTreeIsClean(t *testing.T) {
	loopID := "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd"
	attempt := 1
	workspaceDir, workdir := setupCheckerSnapshotRepo(t, loopID, attempt, "pass", "")

	before := gitCommitCount(t, workdir)

	var mu sync.Mutex
	var events []sentEvent
	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	lp := &LoopProcess{
		workdir:      workdir,
		workspaceDir: workspaceDir,
		attempt:      attempt,
	}
	scope := map[string]interface{}{
		"role":           "checker",
		"workspace_slug": "scope",
		"ticket_id":      "22222222-2222-4222-8222-222222222222",
	}

	mgr.handleCheckerResult(loopID, lp, &adapter.ExitResult{ExitCode: 0}, "sess-2", scope)

	after := gitCommitCount(t, workdir)
	if after != before {
		t.Fatalf("commit count = %d, want %d", after, before)
	}

	event := findEventByName(t, events, "attempt_complete")
	if event.Payload["snapshot_commit_created"] != false {
		t.Fatalf("snapshot_commit_created = %v, want false", event.Payload["snapshot_commit_created"])
	}
	if _, ok := event.Payload["snapshot_commit_sha"]; ok {
		t.Fatalf("snapshot_commit_sha should be omitted when no commit is created")
	}
	if _, ok := event.Payload["snapshot_commit_message"]; ok {
		t.Fatalf("snapshot_commit_message should be omitted when no commit is created")
	}
}

func TestCheckerSnapshotFailureSendsErrorAndBlocksCompletion(t *testing.T) {
	loopID := "efefefef-efef-4fef-8fef-efefefefefef"
	attempt := 3
	workspaceDir, workdir := setupCheckerSnapshotRepo(t, loopID, attempt, "fail", "checker: fail snapshot hits git lock")

	if err := os.WriteFile(filepath.Join(workdir, "broken.txt"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatalf("write dirty file: %v", err)
	}
	if err := os.WriteFile(filepath.Join(workdir, ".git", "index.lock"), []byte("lock"), 0o644); err != nil {
		t.Fatalf("write git index.lock: %v", err)
	}

	before := gitCommitCount(t, workdir)

	var mu sync.Mutex
	var events []sentEvent
	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	lp := &LoopProcess{
		workdir:      workdir,
		workspaceDir: workspaceDir,
		attempt:      attempt,
	}
	scope := map[string]interface{}{
		"role":           "checker",
		"workspace_slug": "scope",
		"ticket_id":      "33333333-3333-4333-8333-333333333333",
	}

	mgr.handleCheckerResult(loopID, lp, &adapter.ExitResult{ExitCode: 0}, "sess-3", scope)

	after := gitCommitCount(t, workdir)
	if after != before {
		t.Fatalf("commit count = %d, want %d", after, before)
	}

	if hasEvent(events, "attempt_complete") {
		t.Fatal("attempt_complete should not be emitted when snapshot commit fails")
	}

	errorEvent := findEventByName(t, events, "error")
	msg, _ := errorEvent.Payload["message"].(string)
	if !strings.Contains(msg, "git add -A") {
		t.Fatalf("error message = %q, want git command context", msg)
	}
	if !strings.Contains(msg, "index.lock") {
		t.Fatalf("error message = %q, want actionable git stderr text", msg)
	}
	if errorEvent.Payload["recoverable"] != false {
		t.Fatalf("recoverable = %v, want false", errorEvent.Payload["recoverable"])
	}
}

func TestCheckerSnapshotInvalidCommitTitleFailsClosed(t *testing.T) {
	loopID := "abab1212-abab-4bab-8bab-ababab121212"
	attempt := 4
	workspaceDir, workdir := setupCheckerSnapshotRepo(t, loopID, attempt, "fail", "   ")

	if err := os.WriteFile(filepath.Join(workdir, "invalid-title.txt"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatalf("write dirty file: %v", err)
	}

	before := gitCommitCount(t, workdir)

	var mu sync.Mutex
	var events []sentEvent
	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	lp := &LoopProcess{
		workdir:      workdir,
		workspaceDir: workspaceDir,
		attempt:      attempt,
	}
	scope := map[string]interface{}{
		"role":           "checker",
		"workspace_slug": "scope",
		"ticket_id":      "34343434-3434-4343-8434-343434343434",
	}

	mgr.handleCheckerResult(loopID, lp, &adapter.ExitResult{ExitCode: 0}, "sess-invalid-title", scope)

	after := gitCommitCount(t, workdir)
	if after != before {
		t.Fatalf("commit count = %d, want %d", after, before)
	}
	if hasEvent(events, "attempt_complete") {
		t.Fatal("attempt_complete should not be emitted when commit_title is invalid")
	}

	errorEvent := findEventByName(t, events, "error")
	msg, _ := errorEvent.Payload["message"].(string)
	if !strings.Contains(msg, "invalid checker commit_title") {
		t.Fatalf("error message = %q, want commit_title context", msg)
	}
	if !strings.Contains(msg, "missing commit_title") {
		t.Fatalf("error message = %q, want explicit validation cause", msg)
	}
	if errorEvent.Payload["recoverable"] != false {
		t.Fatalf("recoverable = %v, want false", errorEvent.Payload["recoverable"])
	}
}

func TestCheckerSnapshotRetryFlowMakerStartsFromSnapshotSHA(t *testing.T) {
	loopID := "f0f0f0f0-f0f0-40f0-80f0-f0f0f0f0f0f0"
	attempt := 1
	workspaceDir, workdir := setupCheckerSnapshotRepo(t, loopID, attempt, "fail", "checker: fail snapshot enables maker retry")

	if err := os.WriteFile(filepath.Join(workdir, "retry.txt"), []byte("retry-state\n"), 0o644); err != nil {
		t.Fatalf("write retry file: %v", err)
	}

	script := "#!/bin/sh\ngit rev-parse HEAD > \"$ALGEDONIA_WORKDIR/.maker_head\"\n"
	reg, repoRoot := setupMockAgent(t, "claude", script)

	var mu sync.Mutex
	var events []sentEvent
	mgr := NewManager(collectingSendFunc(&mu, &events), reg, repoRoot)

	lp := &LoopProcess{
		workdir:      workdir,
		workspaceDir: workspaceDir,
		attempt:      attempt,
	}
	scope := map[string]interface{}{
		"role":           "checker",
		"workspace_slug": "scope",
		"ticket_id":      "44444444-4444-4444-8444-444444444444",
	}

	mgr.handleCheckerResult(loopID, lp, &adapter.ExitResult{ExitCode: 0}, "sess-4", scope)

	checkerEvent := findEventByName(t, events, "attempt_complete")
	snapshotSHA, _ := checkerEvent.Payload["snapshot_commit_sha"].(string)
	if strings.TrimSpace(snapshotSHA) == "" {
		t.Fatal("snapshot_commit_sha is empty")
	}

	err := mgr.StartLoopWithAdapter(
		context.Background(),
		"99999999-9999-4999-8999-999999999999",
		"claude_code",
		"maker",
		workdir,
		workspaceDir,
		"scope",
		"55555555-5555-4555-8555-555555555555",
		"run maker",
		"",
		"",
		attempt+1,
	)
	if err != nil {
		t.Fatalf("StartLoopWithAdapter maker: %v", err)
	}

	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for maker attempt to finish")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	makerHeadRaw, err := os.ReadFile(filepath.Join(workdir, ".maker_head"))
	if err != nil {
		t.Fatalf("read maker head file: %v", err)
	}
	makerHead := strings.TrimSpace(string(makerHeadRaw))
	if makerHead != snapshotSHA {
		t.Fatalf("maker started at %s, want snapshot sha %s", makerHead, snapshotSHA)
	}
}

func setupCheckerSnapshotRepo(t *testing.T, loopID string, attempt int, verdict, commitTitle string) (string, string) {
	t.Helper()

	workspaceDir := t.TempDir()
	workdir := filepath.Join(workspaceDir, "worktrees", "abcdef12")
	if err := os.MkdirAll(workdir, 0o755); err != nil {
		t.Fatalf("mkdir workdir: %v", err)
	}

	runGitCmd(t, workdir, "init")
	runGitCmd(t, workdir, "config", "user.email", "test@example.com")
	runGitCmd(t, workdir, "config", "user.name", "Test User")

	if err := os.WriteFile(filepath.Join(workdir, "README.md"), []byte("seed\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	runGitCmd(t, workdir, "add", "README.md")
	runGitCmd(t, workdir, "commit", "-m", "initial")

	writeCheckerHandoff(t, workspaceDir, loopID, attempt, verdict, commitTitle)
	return workspaceDir, workdir
}

func writeCheckerHandoff(t *testing.T, workspaceDir, loopID string, attempt int, verdict, commitTitle string) {
	t.Helper()

	jsonPath, feedbackPath := expectedCheckerHandoffPaths(loopID, attempt, workspaceDir)
	if err := os.MkdirAll(filepath.Dir(jsonPath), 0o755); err != nil {
		t.Fatalf("mkdir handoff dir: %v", err)
	}
	if err := os.WriteFile(feedbackPath, []byte("checker feedback\n"), 0o644); err != nil {
		t.Fatalf("write feedback markdown: %v", err)
	}

	handoffJSON, err := json.Marshal(checkerHandoff{
		VERDICT:     verdict,
		FEEDBACK:    feedbackPath,
		CommitTitle: commitTitle,
	})
	if err != nil {
		t.Fatalf("marshal handoff json: %v", err)
	}
	if err := os.WriteFile(jsonPath, handoffJSON, 0o644); err != nil {
		t.Fatalf("write handoff json: %v", err)
	}
}

func gitCommitCount(t *testing.T, dir string) int {
	t.Helper()
	count, err := strconv.Atoi(gitOutput(t, dir, "rev-list", "--count", "HEAD"))
	if err != nil {
		t.Fatalf("parse commit count: %v", err)
	}
	return count
}

func gitOutput(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, string(out))
	}
	return strings.TrimSpace(string(out))
}

func hasEvent(events []sentEvent, eventName string) bool {
	for _, event := range events {
		if event.Event == eventName {
			return true
		}
	}
	return false
}

func findEventByName(t *testing.T, events []sentEvent, eventName string) sentEvent {
	t.Helper()
	for _, event := range events {
		if event.Event == eventName {
			return event
		}
	}
	t.Fatalf("event %q not found in %+v", eventName, events)
	return sentEvent{}
}
