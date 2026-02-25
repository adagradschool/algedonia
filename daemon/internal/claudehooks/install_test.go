package claudehooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallIdempotentNoDuplicateHook(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	exe := "/tmp/ag-bin"
	if err := Install(exe); err != nil {
		t.Fatalf("first install: %v", err)
	}
	if err := Install(exe); err != nil {
		t.Fatalf("second install: %v", err)
	}

	settingsPath := filepath.Join(home, ".claude", "settings.json")
	raw, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatal(err)
	}

	var settings map[string]interface{}
	if err := json.Unmarshal(raw, &settings); err != nil {
		t.Fatal(err)
	}

	hooks, ok := settings["hooks"].(map[string]interface{})
	if !ok {
		t.Fatalf("hooks missing or wrong type")
	}
	stop, ok := hooks["Stop"].([]interface{})
	if !ok {
		t.Fatalf("Stop hooks missing or wrong type")
	}

	count := 0
	for _, rawEntry := range stop {
		entry, _ := rawEntry.(map[string]interface{})
		hookList, _ := entry["hooks"].([]interface{})
		for _, rawHook := range hookList {
			hook, _ := rawHook.(map[string]interface{})
			cmd, _ := hook["command"].(string)
			if strings.Contains(cmd, hookCommandSuffix) {
				count++
			}
		}
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 algedonia hook command, got %d", count)
	}
}

func TestInstallReplacesOldHookCommand(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	settingsPath := filepath.Join(home, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(settingsPath), 0o755); err != nil {
		t.Fatal(err)
	}

	initial := map[string]interface{}{
		"hooks": map[string]interface{}{
			"Stop": []interface{}{
				map[string]interface{}{
					"matcher": "*",
					"hooks": []interface{}{
						map[string]interface{}{"type": "command", "command": "\"/old/ag\" claude-hook stop"},
					},
				},
			},
		},
	}
	raw, _ := json.Marshal(initial)
	if err := os.WriteFile(settingsPath, raw, 0o644); err != nil {
		t.Fatal(err)
	}

	newExe := "/new/ag"
	if err := Install(newExe); err != nil {
		t.Fatalf("install: %v", err)
	}

	afterRaw, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatal(err)
	}
	var after map[string]interface{}
	if err := json.Unmarshal(afterRaw, &after); err != nil {
		t.Fatal(err)
	}

	hooks := after["hooks"].(map[string]interface{})
	stop := hooks["Stop"].([]interface{})

	foundNew := false
	foundOld := false
	for _, rawEntry := range stop {
		entry, _ := rawEntry.(map[string]interface{})
		hookList, _ := entry["hooks"].([]interface{})
		for _, rawHook := range hookList {
			hook, _ := rawHook.(map[string]interface{})
			cmd, _ := hook["command"].(string)
			if strings.Contains(cmd, "\""+newExe+"\" "+hookCommandSuffix) {
				foundNew = true
			}
			if strings.Contains(cmd, "\"/old/ag\" "+hookCommandSuffix) {
				foundOld = true
			}
		}
	}

	if !foundNew {
		t.Fatalf("expected new hook command with %s", newExe)
	}
	if foundOld {
		t.Fatalf("old hook command still present")
	}
}
