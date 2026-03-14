package loopmanager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func setupWorkspaceHandoffPaths(t *testing.T, loopID string, attempt int) (string, string, string) {
	t.Helper()

	wsDir := t.TempDir()
	jsonPath, feedbackPath := expectedCheckerHandoffPaths(loopID, attempt, wsDir)
	if jsonPath == "" || feedbackPath == "" {
		t.Fatalf("expected non-empty workspace handoff paths")
	}
	if err := os.MkdirAll(filepath.Dir(jsonPath), 0o755); err != nil {
		t.Fatal(err)
	}
	return wsDir, jsonPath, feedbackPath
}

func TestLoadCheckerHandoff_RequiresWorkspaceDir(t *testing.T) {
	_, err := loadCheckerHandoff("11111111-1111-4111-8111-111111111111", 1, "", false)
	if err == nil {
		t.Fatal("expected error when workspaceDir is missing")
	}
}

func TestLoadCheckerHandoff_Valid(t *testing.T) {
	loopID := "22222222-2222-4222-8222-222222222222"
	attempt := 1
	wsDir, jsonPath, feedbackPath := setupWorkspaceHandoffPaths(t, loopID, attempt)

	handoff := checkerHandoff{VERDICT: "pass", FEEDBACK: feedbackPath, CommitTitle: "checker: pass snapshot"}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feedbackPath, []byte("All checks pass. Code looks good."), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := loadCheckerHandoff(loopID, attempt, wsDir, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verdict != "pass" {
		t.Errorf("verdict = %q, want %q", result.Verdict, "pass")
	}
	if result.FeedbackPath != filepath.Clean(feedbackPath) {
		t.Errorf("feedback_path = %q, want %q", result.FeedbackPath, filepath.Clean(feedbackPath))
	}
	if result.Feedback != "All checks pass. Code looks good." {
		t.Errorf("feedback = %q", result.Feedback)
	}
	if result.CommitTitle != "" {
		t.Errorf("commit_title = %q, want empty when not required", result.CommitTitle)
	}
}

func TestLoadCheckerHandoff_InvalidJSON(t *testing.T) {
	loopID := "33333333-3333-4333-8333-333333333333"
	attempt := 1
	wsDir, jsonPath, _ := setupWorkspaceHandoffPaths(t, loopID, attempt)

	if err := os.WriteFile(jsonPath, []byte("not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := loadCheckerHandoff(loopID, attempt, wsDir, false)
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestLoadCheckerHandoff_InvalidVerdict(t *testing.T) {
	loopID := "44444444-4444-4444-8444-444444444444"
	attempt := 1
	wsDir, jsonPath, feedbackPath := setupWorkspaceHandoffPaths(t, loopID, attempt)

	handoff := checkerHandoff{VERDICT: "maybe", FEEDBACK: feedbackPath, CommitTitle: "checker: invalid verdict"}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := loadCheckerHandoff(loopID, attempt, wsDir, false)
	if err == nil {
		t.Fatal("expected error for invalid verdict")
	}
}

func TestLoadCheckerHandoff_MismatchedFeedbackPath(t *testing.T) {
	loopID := "55555555-5555-4555-8555-555555555555"
	attempt := 1
	wsDir, jsonPath, _ := setupWorkspaceHandoffPaths(t, loopID, attempt)

	handoff := checkerHandoff{VERDICT: "pass", FEEDBACK: "/tmp/wrong/path.md", CommitTitle: "checker: wrong feedback path"}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := loadCheckerHandoff(loopID, attempt, wsDir, false)
	if err == nil {
		t.Fatal("expected error for mismatched feedback path")
	}
}

func TestLoadCheckerHandoff_EmptyFeedbackMarkdown(t *testing.T) {
	loopID := "66666666-6666-4666-8666-666666666666"
	attempt := 1
	wsDir, jsonPath, feedbackPath := setupWorkspaceHandoffPaths(t, loopID, attempt)

	handoff := checkerHandoff{VERDICT: "fail", FEEDBACK: feedbackPath, CommitTitle: "checker: fail snapshot"}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feedbackPath, []byte("  \n "), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := loadCheckerHandoff(loopID, attempt, wsDir, false)
	if err == nil {
		t.Fatal("expected error for empty feedback markdown")
	}
}

func TestLoadCheckerHandoff_RelativeFeedbackPathResolvesInWorkspace(t *testing.T) {
	loopID := "77777777-7777-4777-8777-777777777777"
	attempt := 1
	wsDir, jsonPath, feedbackPath := setupWorkspaceHandoffPaths(t, loopID, attempt)

	relative := filepath.ToSlash(filepath.Join("handoffs", loopID, "attempt-1", "checker_feedback.md"))
	handoff := checkerHandoff{VERDICT: "pass", FEEDBACK: relative, CommitTitle: "checker: relative feedback path"}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feedbackPath, []byte("Workspace-relative feedback path works."), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := loadCheckerHandoff(loopID, attempt, wsDir, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verdict != "pass" {
		t.Errorf("verdict = %q, want pass", result.Verdict)
	}
	if result.FeedbackPath != filepath.Clean(feedbackPath) {
		t.Errorf("feedback_path = %q, want %q", result.FeedbackPath, filepath.Clean(feedbackPath))
	}
	if result.Feedback != "Workspace-relative feedback path works." {
		t.Errorf("feedback = %q", result.Feedback)
	}
}

func TestLoadCheckerHandoff_RequiresCommitTitleOnlyWhenRequested(t *testing.T) {
	loopID := "88888888-8888-4888-8888-888888888888"
	attempt := 1
	wsDir, jsonPath, feedbackPath := setupWorkspaceHandoffPaths(t, loopID, attempt)

	handoff := checkerHandoff{VERDICT: "pass", FEEDBACK: feedbackPath}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feedbackPath, []byte("Feedback is present."), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := loadCheckerHandoff(loopID, attempt, wsDir, false); err != nil {
		t.Fatalf("unexpected error without commit title requirement: %v", err)
	}

	_, err := loadCheckerHandoff(loopID, attempt, wsDir, true)
	if err == nil {
		t.Fatal("expected error when commit_title is required")
	}
	if err.Error() != "missing commit_title" {
		t.Fatalf("error = %q, want missing commit_title", err)
	}
}

func TestLoadCheckerHandoff_InvalidCommitTitleWhenRequired(t *testing.T) {
	loopID := "99999999-9999-4999-8999-999999999999"
	attempt := 1
	wsDir, jsonPath, feedbackPath := setupWorkspaceHandoffPaths(t, loopID, attempt)

	handoff := checkerHandoff{
		VERDICT:     "fail",
		FEEDBACK:    feedbackPath,
		CommitTitle: "checker: fail snapshot\nwith body",
	}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feedbackPath, []byte("Feedback is present."), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := loadCheckerHandoff(loopID, attempt, wsDir, true)
	if err == nil {
		t.Fatal("expected error for invalid commit_title")
	}
	if err.Error() != "commit_title must be a single line" {
		t.Fatalf("error = %q, want single-line validation", err)
	}
}

func TestLoadCheckerHandoff_RejectsControlCharactersInCommitTitle(t *testing.T) {
	loopID := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	attempt := 1
	wsDir, jsonPath, feedbackPath := setupWorkspaceHandoffPaths(t, loopID, attempt)

	handoff := checkerHandoff{
		VERDICT:     "pass",
		FEEDBACK:    feedbackPath,
		CommitTitle: "checker:\x07 invalid title",
	}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feedbackPath, []byte("Feedback is present."), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := loadCheckerHandoff(loopID, attempt, wsDir, true)
	if err == nil {
		t.Fatal("expected error for control-character commit_title")
	}
	if err.Error() != "commit_title contains invalid control characters" {
		t.Fatalf("error = %q, want control-character validation", err)
	}
}
