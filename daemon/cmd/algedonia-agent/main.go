package main

import (
	"bufio"
	"context"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strings"
	"syscall"

	"github.com/algedonia/daemon/internal/config"
	"github.com/algedonia/daemon/internal/connection"
	"github.com/algedonia/daemon/internal/loopmanager"
	"github.com/spf13/cobra"
)

func main() {
	rootCmd := &cobra.Command{
		Use:   "ag",
		Short: "Algedonia daemon agent",
	}

	rootCmd.AddCommand(newConnectCmd())
	rootCmd.AddCommand(newLoginCmd())
	rootCmd.AddCommand(newLogoutCmd())

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func newConnectCmd() *cobra.Command {
	var serverURL, token, name string
	var capacity int

	cmd := &cobra.Command{
		Use:   "connect",
		Short: "Connect to the Phoenix server and maintain heartbeat",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("loading config: %w", err)
			}

			// Config values are defaults; CLI flags override.
			if !cmd.Flags().Changed("server-url") && cfg.ServerURL != "" {
				serverURL = cfg.ServerURL
			}
			if !cmd.Flags().Changed("token") && cfg.Token != "" {
				token = cfg.Token
			}
			if !cmd.Flags().Changed("name") && cfg.Name != "" {
				name = cfg.Name
			}

			if token == "" {
				return fmt.Errorf("--token is required (or run 'ag login' first)")
			}

			if name == "" {
				h, err := os.Hostname()
				if err != nil {
					return fmt.Errorf("getting hostname: %w", err)
				}
				name = h
			}

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			sigCh := make(chan os.Signal, 1)
			signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

			client := connection.NewClient(serverURL, token, name, capacity)

			mgr := loopmanager.NewManager(client.SendEvent)
			client.RegisterHandler("start_loop", mgr.HandleStartLoop)
			client.RegisterHandler("stop_loop", mgr.HandleStopLoop)
			client.SetRunningLoopsFn(mgr.RunningCount)

			go func() {
				<-sigCh
				fmt.Println("\nShutting down...")
				cancel()
			}()

			// Open browser for auth after connection setup
			if authURL, err := buildAuthURL(serverURL, name, token); err == nil {
				openBrowser(authURL)
			}

			return client.RunForever(ctx)
		},
	}

	cmd.Flags().StringVar(&serverURL, "server-url", "ws://localhost:4000/daemon/websocket", "Phoenix server WebSocket URL")
	cmd.Flags().StringVar(&token, "token", "", "Project token for authentication")
	cmd.Flags().StringVar(&name, "name", "", "Daemon name (default: hostname)")
	cmd.Flags().IntVar(&capacity, "capacity", 3, "Max concurrent loops")

	return cmd
}

func newLoginCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "login",
		Short: "Save connection config to ~/.config/ag/config.json",
		RunE: func(cmd *cobra.Command, args []string) error {
			reader := bufio.NewReader(os.Stdin)

			// Load existing config for defaults.
			existing, _ := config.Load()

			serverURL := prompt(reader, "Server URL", existing.ServerURL, "ws://localhost:4000/daemon/websocket")
			token := prompt(reader, "Token", existing.Token, "")
			name := prompt(reader, "Name", existing.Name, "")

			if token == "" {
				return fmt.Errorf("token is required")
			}

			cfg := &config.Config{
				ServerURL: serverURL,
				Token:     token,
				Name:      name,
			}

			if err := config.Save(cfg); err != nil {
				return err
			}

			p, _ := config.Path()
			fmt.Printf("Config saved to %s\n", p)
			return nil
		},
	}
}

func newLogoutCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "logout",
		Short: "Remove saved connection config",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := config.Remove(); err != nil {
				return err
			}
			fmt.Println("Config removed.")
			return nil
		},
	}
}

// buildAuthURL derives an HTTP auth URL from the WebSocket server URL.
func buildAuthURL(wsURL, name, token string) (string, error) {
	u, err := url.Parse(wsURL)
	if err != nil {
		return "", fmt.Errorf("parsing server URL: %w", err)
	}

	switch u.Scheme {
	case "ws":
		u.Scheme = "http"
	case "wss":
		u.Scheme = "https"
	}

	u.Path = "/auth"
	q := u.Query()
	q.Set("name", name)
	q.Set("token", token)
	u.RawQuery = q.Encode()

	return u.String(), nil
}

// openBrowser opens the given URL in the user's default browser.
func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "linux":
		cmd = exec.Command("xdg-open", url)
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
