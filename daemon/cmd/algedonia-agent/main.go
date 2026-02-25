package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
	"github.com/algedonia/daemon/internal/auth"
	"github.com/algedonia/daemon/internal/claudehooks"
	"github.com/algedonia/daemon/internal/config"
	"github.com/algedonia/daemon/internal/connection"
	"github.com/algedonia/daemon/internal/loopmanager"
	"github.com/spf13/cobra"
)

func main() {
	var showVersion bool

	rootCmd := &cobra.Command{
		Use:   "ag",
		Short: "Algedonia daemon agent",
	}

	rootCmd.PersistentFlags().BoolVar(&showVersion, "version", false, "Print version and exit")
	rootCmd.PersistentPreRunE = func(cmd *cobra.Command, args []string) error {
		if showVersion {
			fmt.Fprintln(cmd.OutOrStdout(), version)
			os.Exit(0)
		}
		return nil
	}

	rootCmd.AddCommand(newLoginCmd())
	rootCmd.AddCommand(newLogoutCmd())
	rootCmd.AddCommand(newUninstallCmd())
	rootCmd.AddCommand(newClaudeHookCmd())

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func newLoginCmd() *cobra.Command {
	var serverURL, name string
	var capacity int
	var installClaudeHooks bool

	cmd := &cobra.Command{
		Use:   "login",
		Short: "Authenticate with GitHub and connect to the server",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("loading config: %w", err)
			}

			// Config values are defaults; CLI flags override.
			if !cmd.Flags().Changed("server-url") && cfg.ServerURL != "" {
				serverURL = cfg.ServerURL
			}
			if !cmd.Flags().Changed("name") && cfg.Name != "" {
				name = cfg.Name
			}

			if name == "" {
				h, err := os.Hostname()
				if err != nil {
					return fmt.Errorf("getting hostname: %w", err)
				}
				name = h
			}

			// Re-use saved token or run device flow
			token := cfg.Token
			if token == "" {
				t, err := runDeviceFlow(serverURL)
				if err != nil {
					return err
				}
				token = t

				cfg.Token = token
				cfg.ServerURL = serverURL
				cfg.Name = name
				_ = config.Save(cfg)
			} else {
				fmt.Println("Using saved credentials.")
			}

			if installClaudeHooks {
				exePath, err := os.Executable()
				if err != nil {
					return fmt.Errorf("resolve executable for claude hooks: %w", err)
				}
				if err := claudehooks.Install(exePath); err != nil {
					return fmt.Errorf("install claude hooks: %w", err)
				}
				fmt.Println("Claude Stop hook registered.")
			}

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			sigCh := make(chan os.Signal, 1)
			signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

			client := connection.NewClient(serverURL, token, name, capacity)

			registry := adapter.DefaultRegistry()
			repoRoot, _ := os.Getwd()
			mgr := loopmanager.NewManager(client.SendEvent, registry, repoRoot)
			client.RegisterHandler("start_loop", mgr.HandleStartLoop)
			client.RegisterHandler("stop_loop", mgr.HandleStopLoop)
			client.RegisterHandler("stdin_input", mgr.HandleStdinInput)
			client.SetRunningLoopsFn(mgr.RunningCount)

			go func() {
				<-sigCh
				fmt.Println("\nShutting down...")
				cancel()
			}()

			return client.RunForever(ctx)
		},
	}

	cmd.Flags().StringVar(&serverURL, "server-url", "ws://localhost:4000/daemon/websocket", "Phoenix server WebSocket URL")
	cmd.Flags().StringVar(&name, "name", "", "Daemon name (default: hostname)")
	cmd.Flags().IntVar(&capacity, "capacity", 3, "Max concurrent loops")
	cmd.Flags().BoolVar(&installClaudeHooks, "install-claude-hooks", true, "Install/refresh Claude Stop hook for attempt completion markers")

	return cmd
}

func newLogoutCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "logout",
		Short: "Remove saved credentials and disconnect",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := config.Remove(); err != nil {
				return err
			}
			fmt.Println("Logged out. Credentials removed.")
			return nil
		},
	}
}

func newClaudeHookCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:    "claude-hook",
		Short:  "Internal Claude hook handlers",
		Hidden: true,
	}

	stopCmd := &cobra.Command{
		Use:    "stop",
		Short:  "Claude Stop hook callback",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			loopID := strings.TrimSpace(os.Getenv("ALGEDONIA_LOOP_ID"))
			if loopID == "" {
				return nil
			}

			workdir := strings.TrimSpace(os.Getenv("ALGEDONIA_WORKDIR"))
			if workdir == "" {
				cwd, err := os.Getwd()
				if err != nil {
					return nil
				}
				workdir = cwd
			}
			role := strings.TrimSpace(os.Getenv("ALGEDONIA_ROLE"))

			markerPath := filepath.Join(workdir, ".algedonia", "runtime", loopID, "attempt_complete.json")
			if err := os.MkdirAll(filepath.Dir(markerPath), 0o755); err != nil {
				return nil
			}

			payload := map[string]string{
				"loop_id":   loopID,
				"role":      role,
				"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
			}
			data, err := json.Marshal(payload)
			if err != nil {
				return nil
			}
			_ = os.WriteFile(markerPath, data, 0o644)
			return nil
		},
	}

	cmd.AddCommand(stopCmd)
	return cmd
}

func runDeviceFlow(serverURL string) (string, error) {
	baseURL := httpBaseURL(serverURL)
	fmt.Println("Authenticating with GitHub...")

	deviceResp, err := auth.RequestDeviceCode(baseURL)
	if err != nil {
		return "", fmt.Errorf("requesting device code: %w", err)
	}

	fmt.Printf("\nVisit: %s\nEnter code: %s\n\n", deviceResp.VerificationURI, deviceResp.UserCode)
	openBrowser(deviceResp.VerificationURI)
	fmt.Println("Waiting for authorization...")

	token, err := auth.PollForToken(baseURL, deviceResp.DeviceCode, deviceResp.Interval, deviceResp.ExpiresIn)
	if err != nil {
		return "", fmt.Errorf("device flow: %w", err)
	}

	fmt.Println("Authenticated successfully!")
	return token, nil
}

// httpBaseURL derives an HTTP base URL from the WebSocket server URL.
func httpBaseURL(wsURL string) string {
	u, err := url.Parse(wsURL)
	if err != nil {
		return "http://localhost:4000"
	}

	switch u.Scheme {
	case "ws":
		u.Scheme = "http"
	case "wss":
		u.Scheme = "https"
	}

	u.Path = ""
	u.RawQuery = ""
	return u.String()
}

// openBrowser opens the given URL in the user's default browser.
func openBrowser(rawURL string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", rawURL)
	case "linux":
		cmd = exec.Command("xdg-open", rawURL)
	default:
		return
	}
	_ = cmd.Start()
}

// prompt asks the user for input with an optional default value.
func prompt(reader *bufio.Reader, label, current, fallback string) string {
	def := current
	if def == "" {
		def = fallback
	}

	if def != "" {
		fmt.Printf("%s [%s]: ", label, def)
	} else {
		fmt.Printf("%s: ", label)
	}

	line, _ := reader.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	return line
}
