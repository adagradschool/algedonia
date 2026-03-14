package loopmanager

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode"
)

type checkerHandoff struct {
	VERDICT     string `json:"VERDICT"`
	FEEDBACK    string `json:"FEEDBACK"`
	CommitTitle string `json:"commit_title"`
}

type checkerHandoffData struct {
	Verdict      string
	FeedbackPath string
	Feedback     string
	CommitTitle  string
}

func expectedCheckerHandoffPaths(loopID string, attempt int, workspaceDir string) (string, string) {
	workspaceDir = strings.TrimSpace(workspaceDir)
	if workspaceDir == "" {
		return "", ""
	}
	base := filepath.Join(workspaceDir, "handoffs", loopID, fmt.Sprintf("attempt-%d", attempt))
	return filepath.Join(base, "checker_result.json"), filepath.Join(base, "checker_feedback.md")
}

func loadCheckerHandoff(loopID string, attempt int, workspaceDir string, requireCommitTitle bool) (checkerHandoffData, error) {
	expectedFeedbackPath, handoff, err := readCheckerHandoff(loopID, attempt, workspaceDir)
	if err != nil {
		return checkerHandoffData{}, err
	}

	commitTitle, err := normalizeCheckerCommitTitle(handoff.CommitTitle, requireCommitTitle)
	if err != nil {
		return checkerHandoffData{}, err
	}

	verdict := strings.ToLower(strings.TrimSpace(handoff.VERDICT))
	if verdict != "pass" && verdict != "fail" {
		return checkerHandoffData{}, fmt.Errorf("invalid VERDICT %q", handoff.VERDICT)
	}

	feedbackPath := strings.TrimSpace(handoff.FEEDBACK)
	if feedbackPath == "" {
		return checkerHandoffData{}, fmt.Errorf("missing FEEDBACK path")
	}

	absFeedbackPath := strings.TrimSpace(feedbackPath)
	if strings.HasPrefix(absFeedbackPath, "~/") {
		home, err := os.UserHomeDir()
		if err == nil && strings.TrimSpace(home) != "" {
			absFeedbackPath = filepath.Join(home, absFeedbackPath[2:])
		}
	}
	if !filepath.IsAbs(absFeedbackPath) {
		absFeedbackPath = filepath.Join(workspaceDir, absFeedbackPath)
	}
	absFeedbackPath = filepath.Clean(absFeedbackPath)
	expectedFeedbackPath = filepath.Clean(expectedFeedbackPath)
	if absFeedbackPath != expectedFeedbackPath {
		return checkerHandoffData{}, fmt.Errorf("FEEDBACK path must be %s", filepath.Clean(expectedFeedbackPath))
	}

	markdown, err := os.ReadFile(absFeedbackPath)
	if err != nil {
		return checkerHandoffData{}, fmt.Errorf("read FEEDBACK markdown %s: %w", absFeedbackPath, err)
	}

	feedback := strings.TrimSpace(string(markdown))
	if feedback == "" {
		return checkerHandoffData{}, fmt.Errorf("FEEDBACK markdown is empty at %s", absFeedbackPath)
	}

	return checkerHandoffData{
		Verdict:      verdict,
		FeedbackPath: filepath.Clean(absFeedbackPath),
		Feedback:     feedback,
		CommitTitle:  commitTitle,
	}, nil
}

func loadCheckerSnapshotCommitTitle(loopID string, attempt int, workspaceDir string) (string, error) {
	_, handoff, err := readCheckerHandoff(loopID, attempt, workspaceDir)
	if err != nil {
		return "", err
	}

	commitTitle, err := normalizeCheckerCommitTitle(handoff.CommitTitle, true)
	if err != nil {
		return "", err
	}

	return commitTitle, nil
}

func readCheckerHandoff(loopID string, attempt int, workspaceDir string) (string, checkerHandoff, error) {
	handoffPath, expectedFeedbackPath := expectedCheckerHandoffPaths(loopID, attempt, workspaceDir)
	if handoffPath == "" || expectedFeedbackPath == "" {
		return "", checkerHandoff{}, fmt.Errorf("workspaceDir is required for checker handoff paths")
	}

	raw, err := os.ReadFile(handoffPath)
	if err != nil {
		return "", checkerHandoff{}, fmt.Errorf("read %s: %w", handoffPath, err)
	}

	var handoff checkerHandoff
	if err := json.Unmarshal(raw, &handoff); err != nil {
		return "", checkerHandoff{}, fmt.Errorf("decode checker handoff json: %w", err)
	}

	return expectedFeedbackPath, handoff, nil
}

func normalizeCheckerCommitTitle(raw string, required bool) (string, error) {
	normalized := strings.ReplaceAll(raw, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	title := strings.TrimSpace(normalized)

	if title == "" {
		if required {
			return "", fmt.Errorf("missing commit_title")
		}
		return "", nil
	}
	if !required {
		return "", nil
	}
	if strings.Contains(normalized, "\n") {
		return "", fmt.Errorf("commit_title must be a single line")
	}
	for _, r := range title {
		if unicode.IsControl(r) {
			return "", fmt.Errorf("commit_title contains invalid control characters")
		}
	}
	return title, nil
}
