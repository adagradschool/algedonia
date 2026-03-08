// Package config handles persistent CLI configuration stored under ~/.config/<profile>/config.json.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Config holds persistent daemon configuration.
type Config struct {
	ServerURL string `json:"server_url,omitempty"`
	Token     string `json:"token,omitempty"`
	Name      string `json:"name,omitempty"`
	Workspace string `json:"workspace,omitempty"`
}

const defaultProfile = "ag"

var (
	profileMu sync.RWMutex
	profile   = defaultProfile
)

// SetProfile sets the config namespace profile (e.g. "ag", "agd").
func SetProfile(name string) {
	profileMu.Lock()
	defer profileMu.Unlock()
	profile = normalizeProfile(name)
}

func currentProfile() string {
	profileMu.RLock()
	defer profileMu.RUnlock()
	return profile
}

func normalizeProfile(name string) string {
	name = strings.TrimSpace(strings.ToLower(name))
	switch name {
	case "ag", "agd":
		return name
	default:
		return defaultProfile
	}
}

// Path returns the config file path (~/.config/<profile>/config.json).
func Path() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("getting home dir: %w", err)
	}
	return filepath.Join(home, ".config", currentProfile(), "config.json"), nil
}

// Load reads the config file. Returns a zero Config if the file does not exist.
func Load() (*Config, error) {
	p, err := Path()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return &Config{}, nil
		}
		return nil, fmt.Errorf("reading config: %w", err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	return &cfg, nil
}

// Save writes the config to disk, creating parent directories as needed.
func Save(cfg *Config) error {
	p, err := Path()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return fmt.Errorf("creating config dir: %w", err)
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling config: %w", err)
	}

	if err := os.WriteFile(p, data, 0o600); err != nil {
		return fmt.Errorf("writing config: %w", err)
	}
	return nil
}

// Remove deletes the config file. Returns nil if the file does not exist.
func Remove() error {
	p, err := Path()
	if err != nil {
		return err
	}

	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("removing config: %w", err)
	}
	return nil
}
