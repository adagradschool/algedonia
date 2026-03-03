package runtimepath

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// WorkspaceRuntimeDir returns the runtime directory for a workspace:
// ~/.algedonia/workspaces/<workspace>/runtime
func WorkspaceRuntimeDir(workspace string) (string, error) {
	workspace = strings.TrimSpace(workspace)
	if workspace == "" {
		return "", fmt.Errorf("ALGEDONIA_WORKSPACE is required")
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving user home: %w", err)
	}
	if strings.TrimSpace(home) == "" {
		return "", fmt.Errorf("resolving user home: empty home directory")
	}

	return filepath.Join(home, ".algedonia", "workspaces", workspace, "runtime"), nil
}

// AttemptCompleteMarkerPath returns the completion marker path for a loop.
func AttemptCompleteMarkerPath(workspace, loopID string) (string, error) {
	loopID = strings.TrimSpace(loopID)
	if loopID == "" {
		return "", fmt.Errorf("loop ID is required")
	}
	runtimeDir, err := WorkspaceRuntimeDir(workspace)
	if err != nil {
		return "", err
	}
	return filepath.Join(runtimeDir, loopID, "attempt_complete.json"), nil
}
