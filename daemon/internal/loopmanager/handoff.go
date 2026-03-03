package loopmanager

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type checkerHandoff struct {
	VERDICT  string `json:"VERDICT"`
	FEEDBACK string `json:"FEEDBACK"`
}

func expectedCheckerHandoffPaths(loopID string, attempt int, workspaceDir string) (string, string) {
	workspaceDir = strings.TrimSpace(workspaceDir)
	if workspaceDir == "" {
		return "", ""
	}
	base := filepath.Join(workspaceDir, "handoffs", loopID, fmt.Sprintf("attempt-%d", attempt))
	return filepath.Join(base, "checker_result.json"), filepath.Join(base, "checker_feedback.md")
}

func loadCheckerHandoff(loopID string, attempt int, workspaceDir string) (string, string, string, error) {
	handoffPath, expectedFeedbackPath := expectedCheckerHandoffPaths(loopID, attempt, workspaceDir)
	if handoffPath == "" || expectedFeedbackPath == "" {
		return "", "", "", fmt.Errorf("workspaceDir is required for checker handoff paths")
	}

	raw, err := os.ReadFile(handoffPath)
	if err != nil {
		return "", "", "", fmt.Errorf("read %s: %w", handoffPath, err)
	}

	var handoff checkerHandoff
	if err := json.Unmarshal(raw, &handoff); err != nil {
		return "", "", "", fmt.Errorf("decode checker handoff json: %w", err)
	}

	verdict := strings.ToLower(strings.TrimSpace(handoff.VERDICT))
	if verdict != "pass" && verdict != "fail" {
		return "", "", "", fmt.Errorf("invalid VERDICT %q", handoff.VERDICT)
	}

	feedbackPath := strings.TrimSpace(handoff.FEEDBACK)
	if feedbackPath == "" {
		return "", "", "", fmt.Errorf("missing FEEDBACK path")
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
		return "", "", "", fmt.Errorf("FEEDBACK path must be %s", filepath.Clean(expectedFeedbackPath))
	}

	markdown, err := os.ReadFile(absFeedbackPath)
	if err != nil {
		return "", "", "", fmt.Errorf("read FEEDBACK markdown %s: %w", absFeedbackPath, err)
	}

	feedback := strings.TrimSpace(string(markdown))
	if feedback == "" {
		return "", "", "", fmt.Errorf("FEEDBACK markdown is empty at %s", absFeedbackPath)
	}

	return verdict, filepath.Clean(absFeedbackPath), feedback, nil
}
