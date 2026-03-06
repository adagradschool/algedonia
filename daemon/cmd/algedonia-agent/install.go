package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"text/template"

	"github.com/algedonia/daemon/internal/config"
	"github.com/spf13/cobra"
)

const launchdPlistTemplate = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.algedonia.ag</string>
	<key>ProgramArguments</key>
	<array>
		<string>{{.ExePath}}</string>
		<string>login</string>
		<string>--server-url</string>
		<string>{{.ServerURL}}</string>
		<string>--name</string>
		<string>{{.Name}}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>StandardOutPath</key>
	<string>{{.LogDir}}/ag.out.log</string>
	<key>StandardErrorPath</key>
	<string>{{.LogDir}}/ag.err.log</string>
</dict>
</plist>
`

const systemdUnitTemplate = `[Unit]
Description=Algedonia daemon agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart={{.ExePath}} login --server-url {{.ServerURL}} --name {{.Name}}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
`

type serviceTemplateData struct {
	ExePath   string
	ServerURL string
	Name      string
	LogDir    string
}

func newInstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install",
		Short: "Install as a system service that starts on login",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("loading config: %w", err)
			}

			if cfg.Token == "" {
				return fmt.Errorf("not logged in — run `ag login` first")
			}
			if cfg.ServerURL == "" {
				return fmt.Errorf("no server URL configured — run `ag login --server-url <url>` first")
			}

			exePath, err := os.Executable()
			if err != nil {
				return fmt.Errorf("resolving executable path: %w", err)
			}
			exePath, err = filepath.EvalSymlinks(exePath)
			if err != nil {
				return fmt.Errorf("resolving symlinks: %w", err)
			}

			name := cfg.Name
			if name == "" {
				name, _ = os.Hostname()
			}

			switch runtime.GOOS {
			case "darwin":
				return installLaunchd(cmd, exePath, cfg.ServerURL, name)
			case "linux":
				return installSystemd(cmd, exePath, cfg.ServerURL, name)
			default:
				return fmt.Errorf("unsupported platform: %s", runtime.GOOS)
			}
		},
	}
}

func installLaunchd(cmd *cobra.Command, exePath, serverURL, name string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("getting home dir: %w", err)
	}

	agentsDir := filepath.Join(home, "Library", "LaunchAgents")
	if err := os.MkdirAll(agentsDir, 0o755); err != nil {
		return fmt.Errorf("creating LaunchAgents dir: %w", err)
	}

	logDir := filepath.Join(home, "Library", "Logs", "algedonia")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return fmt.Errorf("creating log dir: %w", err)
	}

	plistPath := filepath.Join(agentsDir, "com.algedonia.ag.plist")

	data := serviceTemplateData{
		ExePath:   exePath,
		ServerURL: serverURL,
		Name:      name,
		LogDir:    logDir,
	}

	tmpl, err := template.New("plist").Parse(launchdPlistTemplate)
	if err != nil {
		return fmt.Errorf("parsing plist template: %w", err)
	}

	// Unload existing service if present (ignore errors)
	if _, statErr := os.Stat(plistPath); statErr == nil {
		_ = exec.Command("launchctl", "unload", plistPath).Run()
	}

	f, err := os.Create(plistPath)
	if err != nil {
		return fmt.Errorf("creating plist: %w", err)
	}
	defer f.Close()

	if err := tmpl.Execute(f, data); err != nil {
		return fmt.Errorf("writing plist: %w", err)
	}

	if err := exec.Command("launchctl", "load", plistPath).Run(); err != nil {
		return fmt.Errorf("loading LaunchAgent: %w", err)
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Installed LaunchAgent: %s\n", plistPath)
	fmt.Fprintf(out, "Logs: %s/ag.{out,err}.log\n", logDir)
	fmt.Fprintln(out, "The daemon will now start on login and restart on failure.")
	return nil
}

func installSystemd(cmd *cobra.Command, exePath, serverURL, name string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("getting home dir: %w", err)
	}

	unitDir := filepath.Join(home, ".config", "systemd", "user")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		return fmt.Errorf("creating systemd user dir: %w", err)
	}

	unitPath := filepath.Join(unitDir, "ag.service")

	data := serviceTemplateData{
		ExePath:   exePath,
		ServerURL: serverURL,
		Name:      name,
	}

	tmpl, err := template.New("unit").Parse(systemdUnitTemplate)
	if err != nil {
		return fmt.Errorf("parsing unit template: %w", err)
	}

	var buf strings.Builder
	if err := tmpl.Execute(&buf, data); err != nil {
		return fmt.Errorf("rendering unit: %w", err)
	}

	if err := os.WriteFile(unitPath, []byte(buf.String()), 0o644); err != nil {
		return fmt.Errorf("writing unit file: %w", err)
	}

	if err := exec.Command("systemctl", "--user", "daemon-reload").Run(); err != nil {
		return fmt.Errorf("daemon-reload: %w", err)
	}

	if err := exec.Command("systemctl", "--user", "enable", "--now", "ag").Run(); err != nil {
		return fmt.Errorf("enabling service: %w", err)
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Installed systemd user service: %s\n", unitPath)
	fmt.Fprintln(out, "The daemon will now start on login and restart on failure.")
	fmt.Fprintln(out, "Use `systemctl --user status ag` to check status.")
	return nil
}
