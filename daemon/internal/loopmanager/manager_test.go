package loopmanager

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
	"github.com/algedonia/daemon/internal/repo"
)

type testWorktreeManager struct{}

func (testWorktreeManager) EnsureWorktree(_ context.Context, workspaceDir string, spec repo.WorktreeSpec) (string, error) {
	wtPath := filepath.Join(workspaceDir, "worktrees", spec.TicketPrefix)
	if err := os.MkdirAll(wtPath, 0o755); err != nil {
		return "", err
	}
	return wtPath, nil
}

func (testWorktreeManager) RemoveWorktree(_ context.Context, workspaceDir, ticketPrefix string) error {
	wtPath := filepath.Join(workspaceDir, "worktrees", ticketPrefix)
	if err := os.RemoveAll(wtPath); err != nil {
		return err
	}
	return nil
}

func configureScopedWorktree(t *testing.T, mgr *Manager, workspaceSlug string) {
	t.Helper()
	baseDir := t.TempDir()
	mgr.SetWorkspaceBaseDir(baseDir)
	mgr.SetWorktreeManager(testWorktreeManager{})
	_ = os.MkdirAll(filepath.Join(baseDir, workspaceSlug), 0o755)
}

type sentEvent struct {
	Event   string
	Payload map[string]interface{}
}

func collectingSendFunc(mu *sync.Mutex, events *[]sentEvent) func(string, map[string]interface{}) error {
	return func(event string, payload map[string]interface{}) error {
		mu.Lock()
		defer mu.Unlock()
		*events = append(*events, sentEvent{Event: event, Payload: payload})
		return nil
	}
}

func TestManagerStartAndWait(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "11111111-1111-4111-8111-111111111111", "echo", []string{"hello from loop"}, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}

	// Wait for process to exit
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for loop to exit")
		default:
		}

		mu.Lock()
		found := false
		for _, e := range events {
			if e.Event == "loop_exited" {
				found = true
				break
			}
		}
		mu.Unlock()

		if found {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Verify we got terminal_output and loop_exited
	mu.Lock()
	defer mu.Unlock()

	var hasOutput, hasExited bool
	var outputData string
	for _, e := range events {
		switch e.Event {
		case "terminal_output":
			if e.Payload["loop_id"] != "11111111-1111-4111-8111-111111111111" {
				t.Errorf("terminal_output loop_id = %v, want 11111111-1111-4111-8111-111111111111", e.Payload["loop_id"])
			}
			if encoded, ok := e.Payload["data"].(string); ok {
				decoded, _ := base64.StdEncoding.DecodeString(encoded)
				outputData += string(decoded)
			}
			hasOutput = true
		case "loop_exited":
			if e.Payload["loop_id"] != "11111111-1111-4111-8111-111111111111" {
				t.Errorf("loop_exited loop_id = %v, want 11111111-1111-4111-8111-111111111111", e.Payload["loop_id"])
			}
			exitCode, ok := e.Payload["exit_code"]
			if !ok {
				t.Error("loop_exited missing exit_code")
			}
			// JSON numbers come as float64 from interface{}
			if code, ok := exitCode.(int); ok && code != 0 {
				t.Errorf("exit_code = %v, want 0", code)
			}
			hasExited = true
		}
	}

	if !hasOutput {
		t.Error("no terminal_output event received")
	}
	if !hasExited {
		t.Error("no loop_exited event received")
	}
	if !strings.Contains(outputData, "hello from loop") {
		t.Errorf("output = %q, want it to contain %q", outputData, "hello from loop")
	}

	// Running count should be 0 after exit
	if mgr.RunningCount() != 0 {
		t.Errorf("RunningCount() = %d, want 0", mgr.RunningCount())
	}
}

func TestManagerDuplicateStart(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "22222222-2222-4222-8222-222222222222", "sleep", []string{"10"}, "", "")
	if err != nil {
		t.Fatalf("first StartLoop: %v", err)
	}
	defer mgr.StopLoop("22222222-2222-4222-8222-222222222222", "test cleanup")

	err = mgr.StartLoop(ctx, "22222222-2222-4222-8222-222222222222", "echo", []string{"hi"}, "", "")
	if err == nil {
		t.Fatal("expected error for duplicate loop ID")
	}
}

func TestManagerStopLoop(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "33333333-3333-4333-8333-333333333333", "sleep", []string{"60"}, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}

	if mgr.RunningCount() != 1 {
		t.Errorf("RunningCount() = %d, want 1", mgr.RunningCount())
	}

	err = mgr.StopLoop("33333333-3333-4333-8333-333333333333", "test")
	if err != nil {
		t.Fatalf("StopLoop: %v", err)
	}

	// Process should be gone
	if mgr.RunningCount() != 0 {
		t.Errorf("RunningCount() = %d after stop, want 0", mgr.RunningCount())
	}

	// Should have loop_exited event
	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, e := range events {
		if e.Event == "loop_exited" && e.Payload["loop_id"] == "33333333-3333-4333-8333-333333333333" {
			found = true
		}
	}
	if !found {
		t.Error("no loop_exited event after StopLoop")
	}
}

func TestManagerStopNotFoundIsIdempotent(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	err := mgr.StopLoop("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "test")
	if err != nil {
		t.Fatalf("expected nil for nonexistent loop, got %v", err)
	}
}

func TestHandleStartLoop(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	ctx := context.Background()
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id": "88888888-8888-4888-8888-888888888888",
	})
	if err == nil {
		t.Fatal("expected error for missing required start_loop fields")
	}
}

func TestHandleStartLoopMissingID(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	err := mgr.HandleStartLoop(context.Background(), map[string]interface{}{})
	if err == nil {
		t.Fatal("expected error for missing loop_id")
	}
}

func TestHandleStopLoop(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	ctx := context.Background()
	_ = mgr.StartLoop(ctx, "91919191-9191-4919-8919-919191919191", "sleep", []string{"60"}, "", "")

	err := mgr.HandleStopLoop(ctx, map[string]interface{}{
		"loop_id": "91919191-9191-4919-8919-919191919191",
		"reason":  "test",
	})
	if err != nil {
		t.Fatalf("HandleStopLoop: %v", err)
	}
}

func TestHandleMergePRReportsSuccess(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")
	configureScopedWorktree(t, mgr, "scope")

	original := runPRMergeCommand
	runPRMergeCommand = func(_ context.Context, workdir string, prNumber int) error {
		if prNumber != 42 {
			t.Fatalf("prNumber = %d, want 42", prNumber)
		}
		if !strings.Contains(workdir, filepath.Join("scope", "worktrees")) {
			t.Fatalf("unexpected workdir %q", workdir)
		}
		return nil
	}
	defer func() { runPRMergeCommand = original }()

	err := mgr.HandleMergePR(context.Background(), map[string]interface{}{
		"loop_id":        "99999999-9999-4999-8999-999999999999",
		"workspace_slug": "scope",
		"ticket_id":      "10101010-1010-4010-8010-101010101010",
		"pr_number":      42,
	})
	if err != nil {
		t.Fatalf("HandleMergePR: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()

	if len(events) != 1 {
		t.Fatalf("events len = %d, want 1", len(events))
	}

	event := events[0]
	if event.Event != "pr_merge_result" {
		t.Fatalf("event = %q, want pr_merge_result", event.Event)
	}
	if merged, _ := event.Payload["merged"].(bool); !merged {
		t.Fatalf("merged = %v, want true", event.Payload["merged"])
	}
}

func TestHandleMergePRReportsFailure(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")
	configureScopedWorktree(t, mgr, "scope")

	original := runPRMergeCommand
	runPRMergeCommand = func(_ context.Context, _ string, _ int) error {
		return fmt.Errorf("merge blocked")
	}
	defer func() { runPRMergeCommand = original }()

	err := mgr.HandleMergePR(context.Background(), map[string]interface{}{
		"loop_id":        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
		"workspace_slug": "scope",
		"ticket_id":      "20202020-2020-4020-8020-202020202020",
		"pr_number":      17,
	})
	if err != nil {
		t.Fatalf("HandleMergePR: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()

	if len(events) != 1 {
		t.Fatalf("events len = %d, want 1", len(events))
	}

	event := events[0]
	if event.Event != "pr_merge_result" {
		t.Fatalf("event = %q, want pr_merge_result", event.Event)
	}
	if merged, _ := event.Payload["merged"].(bool); merged {
		t.Fatalf("merged = %v, want false", event.Payload["merged"])
	}
	if message, _ := event.Payload["message"].(string); !strings.Contains(message, "Unable to merge PR #17") {
		t.Fatalf("message = %q, want merge failure text", message)
	}
}

func TestHandlePollReviewPRReportsStatus(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")
	configureScopedWorktree(t, mgr, "scope")

	original := runReviewPRStatusCommand
	runReviewPRStatusCommand = func(
		_ context.Context,
		workdir string,
		prNumber int,
		branchName string,
	) (map[string]interface{}, error) {
		if prNumber != 42 {
			t.Fatalf("prNumber = %d, want 42", prNumber)
		}
		if branchName != "" {
			t.Fatalf("branchName = %q, want empty", branchName)
		}
		if !strings.Contains(workdir, filepath.Join("scope", "worktrees")) {
			t.Fatalf("unexpected workdir %q", workdir)
		}

		return map[string]interface{}{
			"pr_number":      42,
			"merged":         false,
			"ci_state":       "pending",
			"feedback_token": "token-1",
			"polled_at":      "2026-03-09T06:00:00Z",
		}, nil
	}
	defer func() { runReviewPRStatusCommand = original }()

	err := mgr.HandlePollReviewPR(context.Background(), map[string]interface{}{
		"loop_id":        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
		"workspace_slug": "scope",
		"ticket_id":      "30303030-3030-4030-8030-303030303030",
		"pr_number":      42,
	})
	if err != nil {
		t.Fatalf("HandlePollReviewPR: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()

	if len(events) != 1 {
		t.Fatalf("events len = %d, want 1", len(events))
	}

	event := events[0]
	if event.Event != "review_pr_status" {
		t.Fatalf("event = %q, want review_pr_status", event.Event)
	}
	if ok, _ := event.Payload["ok"].(bool); !ok {
		t.Fatalf("ok = %v, want true", event.Payload["ok"])
	}
	if token, _ := event.Payload["feedback_token"].(string); token != "token-1" {
		t.Fatalf("feedback_token = %q, want token-1", token)
	}
}

func TestHandlePollReviewPRResolvesByBranchWhenPRNumberMissing(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")
	configureScopedWorktree(t, mgr, "scope")

	original := runReviewPRStatusCommand
	runReviewPRStatusCommand = func(
		_ context.Context,
		workdir string,
		prNumber int,
		branchName string,
	) (map[string]interface{}, error) {
		if prNumber != 0 {
			t.Fatalf("prNumber = %d, want 0", prNumber)
		}
		if branchName != "review/alg-100-discover-pr" {
			t.Fatalf("branchName = %q, want review/alg-100-discover-pr", branchName)
		}
		if !strings.Contains(workdir, filepath.Join("scope", "worktrees")) {
			t.Fatalf("unexpected workdir %q", workdir)
		}

		return map[string]interface{}{
			"pr_number":      94,
			"pr_url":         "https://github.com/test/repo/pull/94",
			"merged":         true,
			"ci_state":       "success",
			"feedback_token": "token-2",
			"polled_at":      "2026-03-09T06:10:00Z",
		}, nil
	}
	defer func() { runReviewPRStatusCommand = original }()

	err := mgr.HandlePollReviewPR(context.Background(), map[string]interface{}{
		"loop_id":        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
		"workspace_slug": "scope",
		"ticket_id":      "30303030-3030-4030-8030-303030303030",
		"branch_name":    "review/alg-100-discover-pr",
	})
	if err != nil {
		t.Fatalf("HandlePollReviewPR: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()

	if len(events) != 1 {
		t.Fatalf("events len = %d, want 1", len(events))
	}

	event := events[0]
	if event.Event != "review_pr_status" {
		t.Fatalf("event = %q, want review_pr_status", event.Event)
	}
	if prNumber, _ := event.Payload["pr_number"].(int); prNumber != 94 {
		t.Fatalf("pr_number = %v, want 94", event.Payload["pr_number"])
	}
}

func TestSendInput(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	ctx := context.Background()
	// Start cat — it echoes stdin back to stdout via PTY
	err := mgr.StartLoop(ctx, "a1a1a1a1-a1a1-41a1-81a1-a1a1a1a1a1a1", "cat", nil, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	defer mgr.StopLoop("a1a1a1a1-a1a1-41a1-81a1-a1a1a1a1a1a1", "test cleanup")

	// Give cat time to start
	time.Sleep(300 * time.Millisecond)

	err = mgr.SendInput("a1a1a1a1-a1a1-41a1-81a1-a1a1a1a1a1a1", []byte("hello\n"))
	if err != nil {
		t.Fatalf("SendInput: %v", err)
	}

	// Wait for the echo to appear in terminal_output
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for echoed output")
		default:
		}

		mu.Lock()
		var output string
		for _, e := range events {
			if e.Event == "terminal_output" {
				if encoded, ok := e.Payload["data"].(string); ok {
					decoded, _ := base64.StdEncoding.DecodeString(encoded)
					output += string(decoded)
				}
			}
		}
		mu.Unlock()

		if strings.Contains(output, "hello") {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestSendInputNotFound(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	err := mgr.SendInput("cccccccc-cccc-4ccc-8ccc-cccccccccccc", []byte("data"))
	if err == nil {
		t.Fatal("expected error for nonexistent loop")
	}
}

func TestHandleStdinInput(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "b2b2b2b2-b2b2-42b2-82b2-b2b2b2b2b2b2", "cat", nil, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}
	defer mgr.StopLoop("b2b2b2b2-b2b2-42b2-82b2-b2b2b2b2b2b2", "test cleanup")

	time.Sleep(300 * time.Millisecond)

	encoded := base64.StdEncoding.EncodeToString([]byte("world\n"))
	err = mgr.HandleStdinInput(ctx, map[string]interface{}{
		"loop_id": "b2b2b2b2-b2b2-42b2-82b2-b2b2b2b2b2b2",
		"data":    encoded,
	})
	if err != nil {
		t.Fatalf("HandleStdinInput: %v", err)
	}

	// Wait for echo
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for echoed output")
		default:
		}

		mu.Lock()
		var output string
		for _, e := range events {
			if e.Event == "terminal_output" {
				if enc, ok := e.Payload["data"].(string); ok {
					decoded, _ := base64.StdEncoding.DecodeString(enc)
					output += string(decoded)
				}
			}
		}
		mu.Unlock()

		if strings.Contains(output, "world") {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestHandleStdinInputMissingID(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	err := mgr.HandleStdinInput(context.Background(), map[string]interface{}{})
	if err == nil {
		t.Fatal("expected error for missing loop_id")
	}
}

func TestBroadcastTerminalSlowSubscriberDisconnected(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")
	_, ch, _ := mgr.SubscribeTerminal("44444444-4444-4444-8444-444444444444", 0)

	// Fill subscriber queue and trigger overflow handling.
	for i := 0; i < 512; i++ {
		mgr.broadcastTerminal("44444444-4444-4444-8444-444444444444", []byte("x"))
	}

	deadline := time.After(2 * time.Second)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("timed out waiting for overflow subscriber to disconnect")
		}
	}
}

func TestSubscribeTerminalReplayFromSeq(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")
	loopID := "55555555-5555-4555-8555-555555555555"

	for i := 0; i < 5; i++ {
		mgr.broadcastTerminal(loopID, []byte(fmt.Sprintf("chunk-%d", i+1)))
	}

	replay, ch, unsubscribe := mgr.SubscribeTerminal(loopID, 3)
	defer unsubscribe()

	if len(replay) != 3 {
		t.Fatalf("replay len = %d, want 3", len(replay))
	}
	if replay[0].Seq != 3 || replay[1].Seq != 4 || replay[2].Seq != 5 {
		t.Fatalf("unexpected replay seqs: %d, %d, %d", replay[0].Seq, replay[1].Seq, replay[2].Seq)
	}

	mgr.broadcastTerminal(loopID, []byte("chunk-6"))
	select {
	case live := <-ch:
		if live.Seq != 6 {
			t.Fatalf("live seq = %d, want 6", live.Seq)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for live chunk")
	}
}

func TestSubscribeTerminalReplayTrimmedByByteCap(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")
	mgr.replayMax = 12
	loopID := "66666666-6666-4666-8666-666666666666"

	mgr.broadcastTerminal(loopID, []byte("aaaaa")) // seq 1
	mgr.broadcastTerminal(loopID, []byte("bbbbb")) // seq 2
	mgr.broadcastTerminal(loopID, []byte("ccccc")) // seq 3, seq 1 should be trimmed

	replay, _, unsubscribe := mgr.SubscribeTerminal(loopID, 1)
	defer unsubscribe()

	if len(replay) != 2 {
		t.Fatalf("replay len = %d, want 2", len(replay))
	}
	if replay[0].Seq != 2 || replay[1].Seq != 3 {
		t.Fatalf("unexpected replay seqs after trim: %d, %d", replay[0].Seq, replay[1].Seq)
	}
}

func TestBroadcastTerminalGapFreeUnderBurst(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")
	mgr.replayMax = 2 * 1024 * 1024
	loopID := "77777777-7777-4777-8777-777777777777"
	const total = 1000

	for i := 0; i < total; i++ {
		mgr.broadcastTerminal(loopID, []byte("x"))
	}

	replay, _, unsubscribe := mgr.SubscribeTerminal(loopID, 1)
	defer unsubscribe()

	if len(replay) != total {
		t.Fatalf("received %d seqs, want %d", len(replay), total)
	}

	for i := 0; i < total; i++ {
		want := uint64(i + 1)
		if replay[i].Seq != want {
			t.Fatalf("seq[%d] = %d, want %d", i, replay[i].Seq, want)
		}
	}
}

func TestSendFuncError(t *testing.T) {
	// SendFunc that always fails — manager should still function
	mgr := NewManager(func(string, map[string]interface{}) error {
		return fmt.Errorf("send failed")
	}, nil, "")

	ctx := context.Background()
	err := mgr.StartLoop(ctx, "88888888-8888-4888-8888-888888888888", "echo", []string{"hello"}, "", "")
	if err != nil {
		t.Fatalf("StartLoop: %v", err)
	}

	// Wait for exit — should not deadlock
	deadline := time.After(3 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// setupMockAgent creates a mock agent binary and returns a registry + workdir.
func setupMockAgent(t *testing.T, agentName, script string) (*adapter.Registry, string) {
	t.Helper()
	dir := t.TempDir()
	home := t.TempDir()
	t.Setenv("HOME", home)
	scriptPath := filepath.Join(dir, agentName)
	if err := os.WriteFile(scriptPath, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	origPath := os.Getenv("PATH")
	os.Setenv("PATH", dir+":"+origPath)
	t.Cleanup(func() { os.Setenv("PATH", origPath) })

	return adapter.DefaultRegistry(), dir
}

func TestStartLoopWithAdapter(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	script := "#!/bin/sh\necho 'adapter output'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	err := mgr.StartLoopWithAdapter(ctx, "99999999-9999-4999-8999-999999999999", "claude_code", "maker", dir, "", "scope", "10101010-1010-4010-8010-101010101010", "do a thing", "", "", 1)
	if err != nil {
		t.Fatalf("StartLoopWithAdapter: %v", err)
	}

	// Wait for completion
	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for adapter loop to finish")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Should have gotten attempt_complete (exit code 0, non-checker role)
	mu.Lock()
	defer mu.Unlock()
	found := false
	for _, e := range events {
		if e.Event == "attempt_complete" && e.Payload["loop_id"] == "99999999-9999-4999-8999-999999999999" {
			found = true
		}
	}
	if !found {
		t.Error("expected attempt_complete event")
		for _, e := range events {
			t.Logf("  event: %s %v", e.Event, e.Payload)
		}
	}
}

func TestStartLoopWithAdapterPlanningCompletesOnExit(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	script := "#!/bin/sh\necho 'planning done'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	err := mgr.StartLoopWithAdapter(
		ctx,
		"11111111-2222-4333-8444-555555555555",
		"claude_code",
		"planning",
		dir,
		"",
		"scope",
		"10101010-1010-4010-8010-101010101010",
		"plan this ticket",
		"",
		"",
		1,
	)
	if err != nil {
		t.Fatalf("StartLoopWithAdapter: %v", err)
	}

	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for planning loop to finish")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()

	found := false
	for _, e := range events {
		if e.Event == "attempt_complete" && e.Payload["loop_id"] == "11111111-2222-4333-8444-555555555555" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("expected attempt_complete event for planning loop")
	}
}

func TestStartLoopWithAdapterReviewMarkerCompletesTurnWithoutExitingProcess(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	script := `#!/bin/sh
mkdir -p "$ALGEDONIA_RUNTIME_DIR/$ALGEDONIA_LOOP_ID"
sleep 1
cat > "$ALGEDONIA_RUNTIME_DIR/$ALGEDONIA_LOOP_ID/attempt_complete.json" <<'EOF'
{"loop_id":"22222222-3333-4444-8555-666666666666","role":"review","source":"test"}
EOF
sleep 60
`
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	loopID := "22222222-3333-4444-8555-666666666666"
	err := mgr.StartLoopWithAdapter(
		ctx,
		loopID,
		"claude_code",
		"review",
		dir,
		"",
		"scope",
		"20202020-2020-4020-8020-202020202020",
		"review this ticket",
		"",
		"",
		1,
	)
	if err != nil {
		t.Fatalf("StartLoopWithAdapter: %v", err)
	}
	defer mgr.StopLoop(loopID, "test cleanup")

	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for review attempt_complete event")
		default:
		}

		mu.Lock()
		found := false
		for _, e := range events {
			if e.Event == "attempt_complete" && e.Payload["loop_id"] == loopID {
				found = true
				break
			}
		}
		mu.Unlock()

		if found {
			break
		}

		time.Sleep(50 * time.Millisecond)
	}

	if mgr.RunningCount() != 1 {
		t.Fatalf("RunningCount() = %d, want 1 while review process stays alive", mgr.RunningCount())
	}
}

func TestHandleStartLoopWithRole(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	script := "#!/bin/sh\necho 'hello from adapter'\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)
	configureScopedWorktree(t, mgr, "scope")

	ctx := context.Background()
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id":        "c3c3c3c3-c3c3-43c3-83c3-c3c3c3c3c3c3",
		"role":           "maker",
		"agent_type":     "claude_code",
		"workspace_slug": "scope",
		"ticket_id":      "99999999-9999-4999-8999-999999999999",
		"ticket_type":    "feature",
		"ticket_code":    "ALG-999",
		"task":           "implement feature X",
	})
	if err != nil {
		t.Fatalf("HandleStartLoop with role: %v", err)
	}

	// Wait for completion
	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestHandleGetDiffIncludesUntrackedFiles(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	mgr := NewManager(collectingSendFunc(&mu, &events), nil, "")
	baseDir := t.TempDir()
	workspaceSlug := "scope"
	ticketID := "44471e33-dc54-4b79-8abb-c3dc772e3c2a"
	worktreePath := filepath.Join(baseDir, workspaceSlug, "worktrees", "44471e33")

	mgr.SetWorkspaceBaseDir(baseDir)
	mgr.SetWorktreeManager(testWorktreeManager{})

	if err := os.MkdirAll(worktreePath, 0o755); err != nil {
		t.Fatalf("mkdir worktree: %v", err)
	}

	runGitCmd(t, worktreePath, "init")
	runGitCmd(t, worktreePath, "config", "user.email", "test@example.com")
	runGitCmd(t, worktreePath, "config", "user.name", "Test User")

	if err := os.WriteFile(filepath.Join(worktreePath, "README.md"), []byte("seed\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	runGitCmd(t, worktreePath, "add", "README.md")
	runGitCmd(t, worktreePath, "commit", "-m", "initial")

	if err := os.MkdirAll(filepath.Join(worktreePath, ".algedonia"), 0o755); err != nil {
		t.Fatalf("mkdir .algedonia: %v", err)
	}
	if err := os.WriteFile(filepath.Join(worktreePath, ".algedonia", "rubrics.md"), []byte("# Rubrics\n"), 0o644); err != nil {
		t.Fatalf("write untracked rubrics.md: %v", err)
	}

	err := mgr.HandleGetDiff(context.Background(), map[string]interface{}{
		"loop_id":        "d4d4d4d4-d4d4-44d4-84d4-d4d4d4d4d4d4",
		"workspace_slug": workspaceSlug,
		"ticket_id":      ticketID,
	})
	if err != nil {
		t.Fatalf("HandleGetDiff: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()

	var payload map[string]interface{}
	for _, event := range events {
		if event.Event == "diff_result" && event.Payload["loop_id"] == "d4d4d4d4-d4d4-44d4-84d4-d4d4d4d4d4d4" {
			payload = event.Payload
			break
		}
	}
	if payload == nil {
		t.Fatal("expected diff_result event")
	}

	if _, ok := payload["error"]; ok {
		t.Fatalf("unexpected diff error: %v", payload["error"])
	}

	diffText, _ := payload["diff"].(string)
	if !strings.Contains(diffText, ".algedonia/rubrics.md") {
		t.Fatalf("expected untracked .algedonia file in diff, got: %q", diffText)
	}
}

func TestHandleStartLoopWithoutRole(t *testing.T) {
	mgr := NewManager(func(string, map[string]interface{}) error { return nil }, nil, "")

	ctx := context.Background()
	err := mgr.HandleStartLoop(ctx, map[string]interface{}{
		"loop_id":        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
		"agent_type":     "claude_code",
		"workspace_slug": "scope",
		"ticket_id":      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
		"task":           "do work",
	})
	if err == nil {
		t.Fatal("expected error when role is missing")
	}
}

func runGitCmd(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, string(out))
	}
}

func TestSendPromptToTUI(t *testing.T) {
	t.Run("writes chars then CR", func(t *testing.T) {
		var mu sync.Mutex
		var written []byte

		done := make(chan struct{})
		prompt := "hi"

		writeFn := func(data []byte) error {
			mu.Lock()
			written = append(written, data...)
			mu.Unlock()
			return nil
		}

		// Use a goroutine since sendPromptToTUI blocks on warmup.
		finished := make(chan struct{})
		go func() {
			sendPromptToTUI(done, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", prompt, writeFn)
			close(finished)
		}()

		select {
		case <-finished:
		case <-time.After(10 * time.Second):
			t.Fatal("sendPromptToTUI did not complete in time")
		}

		mu.Lock()
		defer mu.Unlock()

		// Expect: 'h', 'i', CR
		expected := "hi\r"
		if string(written) != expected {
			t.Errorf("written bytes = %q, want %q", string(written), expected)
		}
	})

	t.Run("respects done channel cancellation", func(t *testing.T) {
		done := make(chan struct{})
		close(done) // Already cancelled

		var mu sync.Mutex
		var written []byte

		writeFn := func(data []byte) error {
			mu.Lock()
			written = append(written, data...)
			mu.Unlock()
			return nil
		}

		finished := make(chan struct{})
		go func() {
			sendPromptToTUI(done, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "hello", writeFn)
			close(finished)
		}()

		select {
		case <-finished:
		case <-time.After(3 * time.Second):
			t.Fatal("sendPromptToTUI did not respect done channel")
		}

		mu.Lock()
		defer mu.Unlock()

		if len(written) != 0 {
			t.Errorf("expected no writes when done is closed, got %q", string(written))
		}
	})
}

func TestWaitOrDone(t *testing.T) {
	t.Run("returns true when duration elapses", func(t *testing.T) {
		done := make(chan struct{})
		if !waitOrDone(done, time.Millisecond) {
			t.Error("expected true (duration elapsed)")
		}
	})

	t.Run("returns false when done is closed", func(t *testing.T) {
		done := make(chan struct{})
		close(done)
		if waitOrDone(done, time.Hour) {
			t.Error("expected false (done signalled)")
		}
	})
}

func TestAgentCrashReportsError(t *testing.T) {
	var mu sync.Mutex
	var events []sentEvent

	script := "#!/bin/sh\nexit 1\n"
	reg, dir := setupMockAgent(t, "claude", script)

	mgr := NewManager(collectingSendFunc(&mu, &events), reg, dir)

	ctx := context.Background()
	err := mgr.StartLoopWithAdapter(ctx, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "claude_code", "maker", dir, "", "scope", "20202020-2020-4020-8020-202020202020", "do a thing", "", "", 1)
	if err != nil {
		t.Fatalf("StartLoopWithAdapter: %v", err)
	}

	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-deadline:
			t.Fatal("timed out")
		default:
		}
		if mgr.RunningCount() == 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()

	found := false
	for _, e := range events {
		if e.Event == "error" && e.Payload["loop_id"] == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" {
			found = true
			if e.Payload["recoverable"] != true {
				t.Errorf("recoverable = %v, want true", e.Payload["recoverable"])
			}
		}
	}
	if !found {
		t.Error("expected error event for crashed agent")
		for _, e := range events {
			t.Logf("  event: %s %v", e.Event, e.Payload)
		}
	}
}
