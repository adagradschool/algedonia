package loopmanager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadCheckerHandoff_Valid(t *testing.T) {
	loopID := "test-loop-valid"
	attempt := 1

	jsonPath, feedbackPath := expectedCheckerHandoffPaths(loopID, attempt)

	if err := os.MkdirAll(filepath.Dir(jsonPath), 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(filepath.Dir(jsonPath))) })

	// Write valid handoff JSON
	handoff := checkerHandoff{VERDICT: "pass", FEEDBACK: feedbackPath}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0644); err != nil {
		t.Fatal(err)
	}

	// Write feedback markdown
	if err := os.WriteFile(feedbackPath, []byte("All checks pass. Code looks good."), 0644); err != nil {
		t.Fatal(err)
	}

	verdict, fbPath, feedback, err := loadCheckerHandoff(loopID, attempt)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if verdict != "pass" {
		t.Errorf("verdict = %q, want %q", verdict, "pass")
	}
	if fbPath != filepath.Clean(feedbackPath) {
		t.Errorf("feedback_path = %q, want %q", fbPath, filepath.Clean(feedbackPath))
	}
	if feedback != "All checks pass. Code looks good." {
		t.Errorf("feedback = %q", feedback)
	}
}

func TestLoadCheckerHandoff_MissingJSON(t *testing.T) {
	_, _, _, err := loadCheckerHandoff("nonexistent-loop", 1)
	if err == nil {
		t.Fatal("expected error for missing JSON file")
	}
}

func TestLoadCheckerHandoff_InvalidJSON(t *testing.T) {
	loopID := "test-loop-badjson"
	attempt := 1

	jsonPath, _ := expectedCheckerHandoffPaths(loopID, attempt)

	if err := os.MkdirAll(filepath.Dir(jsonPath), 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(filepath.Dir(jsonPath))) })

	if err := os.WriteFile(jsonPath, []byte("not json"), 0644); err != nil {
		t.Fatal(err)
	}

	_, _, _, err := loadCheckerHandoff(loopID, attempt)
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestLoadCheckerHandoff_InvalidVerdict(t *testing.T) {
	loopID := "test-loop-badverdict"
	attempt := 1

	jsonPath, feedbackPath := expectedCheckerHandoffPaths(loopID, attempt)

	if err := os.MkdirAll(filepath.Dir(jsonPath), 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(filepath.Dir(jsonPath))) })

	handoff := checkerHandoff{VERDICT: "maybe", FEEDBACK: feedbackPath}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0644); err != nil {
		t.Fatal(err)
	}

	_, _, _, err := loadCheckerHandoff(loopID, attempt)
	if err == nil {
		t.Fatal("expected error for invalid verdict")
	}
}

func TestLoadCheckerHandoff_EmptyFeedbackPath(t *testing.T) {
	loopID := "test-loop-nofb"
	attempt := 1

	jsonPath, _ := expectedCheckerHandoffPaths(loopID, attempt)

	if err := os.MkdirAll(filepath.Dir(jsonPath), 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(filepath.Dir(jsonPath))) })

	handoff := checkerHandoff{VERDICT: "pass", FEEDBACK: ""}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0644); err != nil {
		t.Fatal(err)
	}

	_, _, _, err := loadCheckerHandoff(loopID, attempt)
	if err == nil {
		t.Fatal("expected error for empty feedback path")
	}
}

func TestLoadCheckerHandoff_MismatchedFeedbackPath(t *testing.T) {
	loopID := "test-loop-mismatch"
	attempt := 1

	jsonPath, _ := expectedCheckerHandoffPaths(loopID, attempt)

	if err := os.MkdirAll(filepath.Dir(jsonPath), 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(filepath.Dir(jsonPath))) })

	// Point to wrong path
	handoff := checkerHandoff{VERDICT: "pass", FEEDBACK: "/tmp/wrong/path.md"}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0644); err != nil {
		t.Fatal(err)
	}

	_, _, _, err := loadCheckerHandoff(loopID, attempt)
	if err == nil {
		t.Fatal("expected error for mismatched feedback path")
	}
}

func TestLoadCheckerHandoff_EmptyFeedbackMarkdown(t *testing.T) {
	loopID := "test-loop-emptyfb"
	attempt := 1

	jsonPath, feedbackPath := expectedCheckerHandoffPaths(loopID, attempt)

	if err := os.MkdirAll(filepath.Dir(jsonPath), 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(filepath.Dir(jsonPath))) })

	handoff := checkerHandoff{VERDICT: "fail", FEEDBACK: feedbackPath}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0644); err != nil {
		t.Fatal(err)
	}

	// Write empty feedback
	if err := os.WriteFile(feedbackPath, []byte("  \n  "), 0644); err != nil {
		t.Fatal(err)
	}

	_, _, _, err := loadCheckerHandoff(loopID, attempt)
	if err == nil {
		t.Fatal("expected error for empty feedback markdown")
	}
}

func TestLoadCheckerHandoff_FailVerdict(t *testing.T) {
	loopID := "test-loop-fail"
	attempt := 1

	jsonPath, feedbackPath := expectedCheckerHandoffPaths(loopID, attempt)

	if err := os.MkdirAll(filepath.Dir(jsonPath), 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(filepath.Dir(filepath.Dir(jsonPath))) })

	handoff := checkerHandoff{VERDICT: "FAIL", FEEDBACK: feedbackPath}
	data, _ := json.Marshal(handoff)
	if err := os.WriteFile(jsonPath, data, 0644); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(feedbackPath, []byte("Tests are failing in module X."), 0644); err != nil {
		t.Fatal(err)
	}

	verdict, _, feedback, err := loadCheckerHandoff(loopID, attempt)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if verdict != "fail" {
		t.Errorf("verdict = %q, want %q (should normalize to lowercase)", verdict, "fail")
	}
	if feedback != "Tests are failing in module X." {
		t.Errorf("feedback = %q", feedback)
	}
}
