package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/algedonia/daemon/internal/config"
	"github.com/spf13/cobra"
)

func newUninstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall",
		Short: "Remove the ag daemon, service, and config",
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			reader := bufio.NewReader(os.Stdin)

			var summary []string
			var warnings []string

			home, err := os.UserHomeDir()
			if err != nil {
				return fmt.Errorf("getting home dir: %w", err)
			}

			if err := stopDaemonProcess(); err != nil {
				warnings = append(warnings, fmt.Sprintf("warning: %v", err))
			}

			if msg, err := stopService(home); err != nil {
				warnings = append(warnings, fmt.Sprintf("warning: %v", err))
			} else if msg != "" {
				summary = append(summary, msg)
			}

			if msg, err := removeServiceFile(home); err != nil {
				warnings = append(warnings, fmt.Sprintf("warning: %v", err))
			} else if msg != "" {
				summary = append(summary, msg)
			}

			if msg, err := removeBinaries(home); err != nil {
				warnings = append(warnings, fmt.Sprintf("warning: %v", err))
			} else if msg != "" {
				summary = append(summary, msg)
			}

			if msg, err := removeConfigDir(reader); err != nil {
				warnings = append(warnings, fmt.Sprintf("warning: %v", err))
			} else if msg != "" {
				summary = append(summary, msg)
			}

			for _, w := range warnings {
				fmt.Fprintln(out, w)
			}

			if len(summary) == 0 {
				fmt.Fprintln(out, "Nothing to remove.")
				return nil
			}

			fmt.Fprintln(out, "Removed:")
			for _, line := range summary {
				fmt.Fprintf(out, "- %s\n", line)
			}
			return nil
		},
	}
}

func stopDaemonProcess() error {
	pkillPath, err := exec.LookPath("pkill")
	if err != nil {
		return nil
	}

	cmd := exec.Command(pkillPath, "-f", "ag connect")
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			// Non-zero exit means nothing matched; ignore.
			return nil
		}
		return fmt.Errorf("stopping daemon process: %w", err)
	}
	return nil
}

func stopService(home string) (string, error) {
	switch runtime.GOOS {
	case "darwin":
		plist := filepath.Join(home, "Library", "LaunchAgents", "com.algedonia.ag.plist")
		if _, err := os.Stat(plist); err != nil {
			if os.IsNotExist(err) {
				return "", nil
			}
			return "", err
		}

		if _, err := exec.LookPath("launchctl"); err != nil {
			return "", fmt.Errorf("launchctl not available")
		}

		cmd := exec.Command("launchctl", "unload", plist)
		if err := cmd.Run(); err != nil {
			return "", fmt.Errorf("unloading launchd service: %w", err)
		}
		return fmt.Sprintf("LaunchAgent unloaded (%s)", plist), nil
	case "linux":
		unit := filepath.Join(home, ".config", "systemd", "user", "ag.service")
		if _, err := os.Stat(unit); err != nil {
			if os.IsNotExist(err) {
				return "", nil
			}
			return "", err
		}

		if _, err := exec.LookPath("systemctl"); err != nil {
			return "", fmt.Errorf("systemctl not available")
		}

		cmd := exec.Command("systemctl", "--user", "disable", "--now", "ag")
		if err := cmd.Run(); err != nil {
			return "", fmt.Errorf("stopping systemd service: %w", err)
		}
		return "Systemd user service disabled", nil
	default:
		return "", nil
	}
}

func removeServiceFile(home string) (string, error) {
	switch runtime.GOOS {
	case "darwin":
		plist := filepath.Join(home, "Library", "LaunchAgents", "com.algedonia.ag.plist")
		if err := os.Remove(plist); err != nil {
			if os.IsNotExist(err) {
				return "", nil
			}
			return "", fmt.Errorf("removing launchd plist: %w", err)
		}
		return fmt.Sprintf("LaunchAgent removed (%s)", plist), nil
	case "linux":
		unit := filepath.Join(home, ".config", "systemd", "user", "ag.service")
		if err := os.Remove(unit); err != nil {
			if os.IsNotExist(err) {
				return "", nil
			}
			return "", fmt.Errorf("removing systemd unit: %w", err)
		}
		return fmt.Sprintf("Systemd unit removed (%s)", unit), nil
	default:
		return "", nil
	}
}

func removeBinaries(home string) (string, error) {
	paths := []string{
		filepath.Join("/usr", "local", "bin", "ag"),
		filepath.Join(home, ".local", "bin", "ag"),
	}

	var removed []string
	for _, p := range paths {
		if _, err := os.Stat(p); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return "", err
		}
		if err := os.Remove(p); err != nil {
			return "", fmt.Errorf("removing binary %s: %w", p, err)
		}
		removed = append(removed, p)
	}

	if len(removed) == 0 {
		return "", nil
	}
	return fmt.Sprintf("Binary removed (%s)", strings.Join(removed, ", ")), nil
}

func removeConfigDir(reader *bufio.Reader) (string, error) {
	configPath, err := config.Path()
	if err != nil {
		return "", err
	}
	configDir := filepath.Dir(configPath)

	if _, err := os.Stat(configDir); err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}

	if !confirm(reader, fmt.Sprintf("Remove config at %s?", configDir)) {
		return "", nil
	}

	if err := os.RemoveAll(configDir); err != nil {
		return "", fmt.Errorf("removing config dir: %w", err)
	}
	return fmt.Sprintf("Config removed (%s)", configDir), nil
}

func confirm(reader *bufio.Reader, prompt string) bool {
	fmt.Printf("%s [y/N]: ", prompt)
	line, _ := reader.ReadString('\n')
	line = strings.TrimSpace(strings.ToLower(line))
	return line == "y" || line == "yes"
}
