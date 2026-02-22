package adapter

import (
	"fmt"
	"os"
	"path/filepath"
)

// PromptPath returns the file path for a given role's prompt file.
func PromptPath(promptsDir, role string) string {
	return filepath.Join(promptsDir, role+".md")
}

// LoadPrompt reads the prompt file for the given role from promptsDir.
func LoadPrompt(promptsDir, role string) (string, error) {
	path := PromptPath(promptsDir, role)
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("loading prompt for role %q from %s: %w", role, path, err)
	}
	return string(data), nil
}
