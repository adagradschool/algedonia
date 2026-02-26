package claudehooks

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const hookCommandSuffix = "claude-hook stop"

func settingsPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("get home dir: %w", err)
	}
	return filepath.Join(home, ".claude", "settings.json"), nil
}

// Install ensures Claude settings include a Stop hook that invokes
// `ag claude-hook stop` using the current executable path.
func Install(executablePath string) error {
	settingsFile, err := settingsPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(settingsFile), 0o755); err != nil {
		return fmt.Errorf("mkdir for claude settings: %w", err)
	}

	settings := map[string]interface{}{}
	if raw, err := os.ReadFile(settingsFile); err == nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, &settings); err != nil {
			return fmt.Errorf("parse claude settings: %w", err)
		}
	}

	hooks, _ := settings["hooks"].(map[string]interface{})
	if hooks == nil {
		hooks = map[string]interface{}{}
	}

	stopHooks, _ := hooks["Stop"].([]interface{})
	if stopHooks == nil {
		stopHooks = []interface{}{}
	}

	command := fmt.Sprintf("%q %s", executablePath, hookCommandSuffix)
	newEntry := map[string]interface{}{
		"matcher": "*",
		"hooks": []interface{}{
			map[string]interface{}{
				"type":    "command",
				"command": command,
			},
		},
	}

	filtered := make([]interface{}, 0, len(stopHooks)+1)
	for _, raw := range stopHooks {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			filtered = append(filtered, raw)
			continue
		}

		keep := true
		if hookList, ok := entry["hooks"].([]interface{}); ok {
			for _, h := range hookList {
				hookMap, ok := h.(map[string]interface{})
				if !ok {
					continue
				}
				cmd, _ := hookMap["command"].(string)
				if strings.Contains(cmd, hookCommandSuffix) {
					keep = false
					break
				}
			}
		}

		if keep {
			filtered = append(filtered, raw)
		}
	}

	hooks["Stop"] = append([]interface{}{newEntry}, filtered...)
	settings["hooks"] = hooks

	out, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal claude settings: %w", err)
	}
	if err := os.WriteFile(settingsFile, out, 0o644); err != nil {
		return fmt.Errorf("write claude settings: %w", err)
	}
	return nil
}
