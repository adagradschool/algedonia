package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/algedonia/daemon/internal/adapter"
	"github.com/algedonia/daemon/internal/auth"
	"github.com/algedonia/daemon/internal/claudehooks"
	"github.com/algedonia/daemon/internal/config"
	"github.com/algedonia/daemon/internal/connection"
	"github.com/algedonia/daemon/internal/loopmanager"
	"github.com/algedonia/daemon/internal/repo"
	"github.com/algedonia/daemon/internal/runtimepath"
	"github.com/algedonia/daemon/internal/terminalws"
	"github.com/spf13/cobra"
)

func main() {
	initCLIProfile()

	var showVersion bool

	rootCmd := &cobra.Command{
		Use:   commandName(),
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
	rootCmd.AddCommand(newInstallCmd())
	rootCmd.AddCommand(newUninstallCmd())
	rootCmd.AddCommand(newClaudeHookCmd())
	rootCmd.AddCommand(newCodexNotifyCmd())
	rootCmd.AddCommand(newTicketCmd())
	rootCmd.AddCommand(newWorkspaceCmd())

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func newLoginCmd() *cobra.Command {
	var serverURL, name string
	var capacity int
	var installClaudeHooks bool
	var installCodexNotify bool
	var terminalWSListen string

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
				if err := config.Save(cfg); err != nil {
					return fmt.Errorf("saving config: %w", err)
				}
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

			if installCodexNotify {
				exePath, err := os.Executable()
				if err != nil {
					return fmt.Errorf("resolve executable for codex notify hook: %w", err)
				}
				if err := installCodexNotifyHook(exePath); err != nil {
					return fmt.Errorf("install codex notify hook: %w", err)
				}
				fmt.Println("Codex notify hook configured.")
			}

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			sigCh := make(chan os.Signal, 1)
			signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

			client := connection.NewClient(serverURL, token, name, capacity)

			registry := adapter.DefaultRegistry()
			repoRoot, err := os.Getwd()
			if err != nil {
				return fmt.Errorf("getting working directory: %w", err)
			}
			mgr := loopmanager.NewManager(client.SendEvent, registry, repoRoot)
			workspaceBaseDir := ""
			home, _ := os.UserHomeDir()
			if home != "" {
				workspaceBaseDir = filepath.Join(home, ".algedonia", "workspaces")
				mgr.SetWorkspaceBaseDir(workspaceBaseDir)
			}
			wtMgr := repo.NewWorktreeManager("")
			mgr.SetWorktreeManager(wtMgr)
			client.RegisterHandler("start_loop", mgr.HandleStartLoop)
			client.RegisterHandler("stop_loop", mgr.HandleStopLoop)
			client.RegisterHandler("stdin_input", mgr.HandleStdinInput)
			client.RegisterHandler("get_diff", mgr.HandleGetDiff)
			client.RegisterHandler("merge_pr", mgr.HandleMergePR)
			client.RegisterHandler("poll_review_pr", mgr.HandlePollReviewPR)
			client.RegisterHandler("cleanup_worktree", mgr.HandleCleanupWorktree)
			client.RegisterHandler("open_editor", mgr.HandleOpenEditor)
			client.RegisterHandler("run_workspace_script", mgr.HandleRunWorkspaceScript)
			client.SetRunningLoopsFn(mgr.RunningCount)
			client.SetRunningLoopIDFn(mgr.RunningLoopIDs)
			client.SetAvailableAgentsFn(registry.AgentTypes)
			client.SetBareReposFn(func() []string {
				return listBareRepos(workspaceBaseDir)
			})

			cloneMgr := repo.NewCloneManager(workspaceBaseDir, "")
			client.OnJoin(makeJoinCallback(cloneMgr, client))
			client.RegisterHandler("workspaces_sync", makeWorkspaceSyncHandler(cloneMgr, client))

			verifyURL := strings.TrimRight(httpBaseURL(serverURL), "/") + "/api/terminal/verify"
			terminalVerifier := terminalws.NewAPITokenVerifier(verifyURL, token)
			terminalServer := terminalws.NewServer(terminalWSListen, mgr, terminalVerifier)
			if err := terminalServer.Start(ctx); err != nil {
				return fmt.Errorf("starting terminal websocket server: %w", err)
			}
			client.SetTerminalWSURL("ws://" + terminalWSListen + "/terminal/ws")
			log.Printf("Terminal websocket verify endpoint: %s", verifyURL)

			go func() {
				<-sigCh
				fmt.Println("\nShutting down...")
				cancel()
			}()

			return client.RunForever(ctx)
		},
	}

	cmd.Flags().StringVar(&serverURL, "server-url", defaultServerWebsocketURL(), "Phoenix server WebSocket URL")
	cmd.Flags().StringVar(&name, "name", "", "Daemon name (default: hostname)")
	cmd.Flags().IntVar(&capacity, "capacity", 3, "Max concurrent loops")
	cmd.Flags().BoolVar(&installClaudeHooks, "install-claude-hooks", true, "Install/refresh Claude Stop hook for attempt completion markers")
	cmd.Flags().BoolVar(&installCodexNotify, "install-codex-notify", true, "Install/refresh Codex notify hook for turn completion markers")
	cmd.Flags().StringVar(&terminalWSListen, "terminal-ws-listen", defaultTerminalWSListen(), "Terminal WebSocket listen address")

	return cmd
}

func makeJoinCallback(cloneMgr repo.RepoManager, client *connection.Client) connection.JoinCallback {
	return func(ctx context.Context, response map[string]interface{}) {
		log.Printf("Join response payload: %+v", response)
		syncWorkspaces(ctx, response, cloneMgr, client)
	}
}

func makeWorkspaceSyncHandler(
	cloneMgr repo.RepoManager,
	client *connection.Client,
) func(ctx context.Context, payload map[string]interface{}) error {
	return func(ctx context.Context, payload map[string]interface{}) error {
		syncWorkspaces(ctx, payload, cloneMgr, client)
		return nil
	}
}

func syncWorkspaces(
	ctx context.Context,
	payload map[string]interface{},
	cloneMgr repo.RepoManager,
	client *connection.Client,
) {
	workspaces, _ := payload["workspaces"].([]interface{})
	if len(workspaces) == 0 {
		return
	}

	for _, raw := range workspaces {
		ws, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		slug, _ := ws["slug"].(string)
		repoURL, _ := ws["github_repo_url"].(string)

		if slug == "" {
			continue
		}
		if repoURL == "" {
			sendCloneStatus(client, slug, "not_configured", "", "")
			continue
		}

		path, err := cloneMgr.EnsureRepo(ctx, slug, repoURL)
		if err != nil {
			sendCloneStatus(client, slug, "error", "", err.Error())
			continue
		}

		sendCloneStatus(client, slug, "ready", path, "")
	}
}

func sendCloneStatus(client *connection.Client, workspaceSlug, status, path, message string) {
	payload := map[string]interface{}{
		"status":         status,
		"workspace_slug": workspaceSlug,
	}
	if path != "" {
		payload["path"] = path
	}
	if message != "" {
		payload["message"] = message
	}
	if err := client.SendEvent("repo_clone_status", payload); err != nil {
		log.Printf("Failed to send repo_clone_status: %v", err)
	}
}

func listBareRepos(baseDir string) []string {
	if strings.TrimSpace(baseDir) == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return []string{}
		}
		baseDir = filepath.Join(home, ".algedonia", "workspaces")
	}

	entries, err := os.ReadDir(baseDir)
	if err != nil {
		return []string{}
	}

	repos := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		rootPath := filepath.Join(baseDir, entry.Name(), "root")
		if info, err := os.Stat(rootPath); err == nil && info.IsDir() {
			repos = append(repos, entry.Name())
		}
	}

	sort.Strings(repos)
	return repos
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
			workspace := strings.TrimSpace(os.Getenv("ALGEDONIA_WORKSPACE"))
			if workspace == "" {
				log.Printf("Skipping attempt-complete marker: ALGEDONIA_WORKSPACE is required for loop=%s source=claude-stop-hook", loopID)
				return nil
			}
			role := strings.TrimSpace(os.Getenv("ALGEDONIA_ROLE"))

			_ = writeAttemptCompleteMarker(workspace, loopID, role, "claude-stop-hook", nil)
			return nil
		},
	}

	cmd.AddCommand(stopCmd)
	return cmd
}

func newCodexNotifyCmd() *cobra.Command {
	return &cobra.Command{
		Use:    "codex-notify",
		Short:  "Internal Codex notify hook handler",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				return nil
			}

			var notification map[string]interface{}
			if err := json.Unmarshal([]byte(args[0]), &notification); err != nil {
				return nil
			}

			ntype, _ := notification["type"].(string)
			if strings.TrimSpace(ntype) != "agent-turn-complete" {
				return nil
			}

			loopID := strings.TrimSpace(os.Getenv("ALGEDONIA_LOOP_ID"))
			if loopID == "" {
				return nil
			}
			workspace := strings.TrimSpace(os.Getenv("ALGEDONIA_WORKSPACE"))
			if workspace == "" {
				log.Printf("Skipping attempt-complete marker: ALGEDONIA_WORKSPACE is required for loop=%s source=codex-notify", loopID)
				return nil
			}

			role := strings.TrimSpace(os.Getenv("ALGEDONIA_ROLE"))
			_ = writeAttemptCompleteMarker(workspace, loopID, role, "codex-notify", notification)
			return nil
		},
	}
}

func writeAttemptCompleteMarker(
	workspace, loopID, role, source string,
	extra map[string]interface{},
) error {
	if strings.TrimSpace(workspace) == "" || strings.TrimSpace(loopID) == "" {
		return nil
	}
	normalizedRole := strings.ToLower(strings.TrimSpace(role))
	if !roleSupportsCompletionMarker(normalizedRole) {
		log.Printf("Skipping attempt-complete marker for role=%q loop=%s source=%s", normalizedRole, loopID, source)
		return nil
	}

	markerPath, err := runtimepath.AttemptCompleteMarkerPath(workspace, loopID)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(markerPath), 0o755); err != nil {
		return err
	}

	payload := map[string]interface{}{
		"loop_id":   loopID,
		"role":      normalizedRole,
		"source":    source,
		"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
	}
	if extra != nil {
		payload["notification"] = extra
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return os.WriteFile(markerPath, data, 0o644)
}

func roleSupportsCompletionMarker(role string) bool {
	switch strings.ToLower(strings.TrimSpace(role)) {
	case "maker", "checker", "task", "hook", "review":
		return true
	default:
		return false
	}
}

const (
	codexNotifyBlockStart = "# BEGIN ALGEDONIA CODEX NOTIFY"
	codexNotifyBlockEnd   = "# END ALGEDONIA CODEX NOTIFY"
)

func installCodexNotifyHook(exePath string) error {
	codexHome := strings.TrimSpace(os.Getenv("CODEX_HOME"))
	if codexHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("resolve user home for codex config: %w", err)
		}
		codexHome = filepath.Join(home, ".codex")
	}

	if err := os.MkdirAll(codexHome, 0o755); err != nil {
		return fmt.Errorf("create codex home %s: %w", codexHome, err)
	}

	configPath := filepath.Join(codexHome, "config.toml")
	raw, err := os.ReadFile(configPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read codex config %s: %w", configPath, err)
	}

	notifyLine := fmt.Sprintf(`notify = ["%s", "codex-notify"]`, tomlEscapeString(exePath))
	updated := upsertCodexNotifyBlock(string(raw), notifyLine)
	if updated == string(raw) {
		return nil
	}

	if err := os.WriteFile(configPath, []byte(updated), 0o644); err != nil {
		return fmt.Errorf("write codex config %s: %w", configPath, err)
	}
	return nil
}

func upsertCodexNotifyBlock(existing, notifyLine string) string {
	block := strings.Join([]string{codexNotifyBlockStart, notifyLine, codexNotifyBlockEnd}, "\n")

	start := strings.Index(existing, codexNotifyBlockStart)
	end := strings.Index(existing, codexNotifyBlockEnd)
	if start >= 0 && end >= start {
		end += len(codexNotifyBlockEnd)
		updated := existing[:start] + block + existing[end:]
		return ensureTrailingNewline(updated)
	}

	lines := strings.Split(existing, "\n")
	firstTable := len(lines)
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			firstTable = i
			break
		}
	}

	notifyIdx := -1
	for i := 0; i < firstTable; i++ {
		trimmed := strings.TrimSpace(lines[i])
		if strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, "//") {
			continue
		}
		if strings.HasPrefix(trimmed, "notify") && strings.Contains(trimmed, "=") {
			notifyIdx = i
			break
		}
	}

	if notifyIdx >= 0 {
		replaced := append([]string{}, lines[:notifyIdx]...)
		replaced = append(replaced, codexNotifyBlockStart, notifyLine, codexNotifyBlockEnd)
		replaced = append(replaced, lines[notifyIdx+1:]...)
		return ensureTrailingNewline(strings.Join(replaced, "\n"))
	}

	insertAt := firstTable
	if insertAt < 0 || insertAt > len(lines) {
		insertAt = len(lines)
	}
	inserted := append([]string{}, lines[:insertAt]...)
	if insertAt > 0 && strings.TrimSpace(lines[insertAt-1]) != "" {
		inserted = append(inserted, "")
	}
	inserted = append(inserted, codexNotifyBlockStart, notifyLine, codexNotifyBlockEnd)
	if insertAt < len(lines) {
		inserted = append(inserted, lines[insertAt:]...)
	}
	return ensureTrailingNewline(strings.Join(inserted, "\n"))
}

func ensureTrailingNewline(s string) string {
	if strings.HasSuffix(s, "\n") {
		return s
	}
	return s + "\n"
}

func tomlEscapeString(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\"", "\\\"")
	return s
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

func normalizeServerWebsocketURL(raw string) string {
	fallback := fallbackServerWebsocketURL()

	raw = strings.TrimSpace(raw)
	if raw == "" {
		return fallback
	}

	u, err := url.Parse(raw)
	if err != nil || strings.TrimSpace(u.Host) == "" {
		return fallback
	}

	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	case "ws", "wss":
		// keep scheme
	default:
		return fallback
	}

	if strings.TrimSpace(u.Path) == "" || u.Path == "/" {
		u.Path = "/daemon/websocket"
	}

	u.RawQuery = ""
	u.Fragment = ""
	return u.String()
}

// httpBaseURL derives an HTTP base URL from the WebSocket server URL.
func httpBaseURL(wsURL string) string {
	u, err := url.Parse(wsURL)
	if err != nil || strings.TrimSpace(u.Host) == "" {
		return profileDefaultHTTPBaseURL()
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
