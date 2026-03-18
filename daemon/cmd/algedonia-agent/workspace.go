package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/algedonia/daemon/internal/apiclient"
	"github.com/algedonia/daemon/internal/config"
	"github.com/spf13/cobra"
)

var workspaceTarget string

func newWorkspaceCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "workspace",
		Aliases: []string{"ws"},
		Short:   "Manage workspaces",
	}

	cmd.PersistentFlags().StringVar(&workspaceTarget, "workspace", "", "Workspace slug (overrides saved workspace)")

	cmd.AddCommand(newWorkspaceListCmd())
	cmd.AddCommand(newWorkspaceShowCmd())
	cmd.AddCommand(newWorkspaceUpdateCmd())
	cmd.AddCommand(newWorkspaceUseCmd())

	return cmd
}

func newWorkspaceListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List available workspaces",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, cfg, err := newAPIClient("")
			if err != nil {
				return err
			}

			workspaces, err := client.ListWorkspaces()
			if err != nil {
				return fmt.Errorf("listing workspaces: %w", err)
			}

			if len(workspaces) == 0 {
				fmt.Fprintln(cmd.ErrOrStderr(), "No workspaces found.")
				return nil
			}

			w := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			for _, ws := range workspaces {
				marker := " "
				if ws.Slug == cfg.Workspace {
					marker = "*"
				}
				fmt.Fprintf(w, "%s\t%s\t%s\n", marker, ws.Slug, ws.Name)
			}
			return w.Flush()
		},
	}
}

func newWorkspaceShowCmd() *cobra.Command {
	var jsonOutput bool

	cmd := &cobra.Command{
		Use:   "show",
		Short: "Show current workspace settings",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := workspaceClient()
			if err != nil {
				return err
			}

			workspace, err := client.GetWorkspace()
			if err != nil {
				return fmt.Errorf("getting workspace: %w", humanizeWorkspaceAPIError(err))
			}

			if jsonOutput {
				return printJSONTo(cmd.OutOrStdout(), workspace)
			}

			printWorkspace(cmd.OutOrStdout(), workspace)
			return nil
		},
	}

	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")

	return cmd
}

func newWorkspaceUpdateCmd() *cobra.Command {
	var (
		name                    string
		githubRepoURL           string
		maxIterations           int
		worktreeBootstrapScript string
		worktreeRunScript       string
		jsonOutput              bool
	)

	cmd := &cobra.Command{
		Use:   "update",
		Short: "Update current workspace settings",
		Long:  "Update editable workspace settings. Prefix remains derived from the workspace name.",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, cfg, err := newAPIClient(workspaceTarget)
			if err != nil {
				return err
			}
			if client.Workspace == "" {
				return fmt.Errorf("no workspace set — use --workspace, set ALGEDONIA_WORKSPACE, or run `%s workspace use <slug>`", commandName())
			}

			attrs := map[string]interface{}{}
			if cmd.Flags().Changed("name") {
				attrs["name"] = name
			}
			if cmd.Flags().Changed("github-repo-url") {
				attrs["github_repo_url"] = githubRepoURL
			}
			if cmd.Flags().Changed("max-iterations") {
				attrs["max_iterations"] = maxIterations
			}
			if cmd.Flags().Changed("worktree-bootstrap-script") {
				attrs["worktree_bootstrap_script"] = worktreeBootstrapScript
			}
			if cmd.Flags().Changed("worktree-run-script") {
				attrs["worktree_run_script"] = worktreeRunScript
			}

			if len(attrs) == 0 {
				return fmt.Errorf("no fields to update — specify at least one flag")
			}

			originalSlug := client.Workspace
			workspace, err := client.UpdateWorkspace(attrs)
			if err != nil {
				return fmt.Errorf("updating workspace: %w", humanizeWorkspaceAPIError(err))
			}

			if cfg.Workspace == originalSlug && workspace.Slug != originalSlug {
				cfg.Workspace = workspace.Slug
				if err := config.Save(cfg); err != nil {
					return fmt.Errorf("saving renamed active workspace: %w", err)
				}
			}

			if jsonOutput {
				return printJSONTo(cmd.OutOrStdout(), workspace)
			}

			printWorkspace(cmd.OutOrStdout(), workspace)
			return nil
		},
	}

	cmd.Flags().StringVar(&name, "name", "", "Workspace name")
	cmd.Flags().StringVar(&githubRepoURL, "github-repo-url", "", "GitHub repository URL")
	cmd.Flags().IntVar(&maxIterations, "max-iterations", 0, "Default iteration budget (1-50)")
	cmd.Flags().StringVar(&worktreeBootstrapScript, "worktree-bootstrap-script", "", "Script run in new ticket worktrees")
	cmd.Flags().StringVar(&worktreeRunScript, "worktree-run-script", "", "Script run manually in ticket worktrees")
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output as JSON")

	return cmd
}

func newWorkspaceUseCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "use <slug>",
		Short: "Set the active workspace",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("loading config: %w", err)
			}

			cfg.Workspace = args[0]
			if err := config.Save(cfg); err != nil {
				return fmt.Errorf("saving config: %w", err)
			}

			fmt.Fprintf(cmd.OutOrStdout(), "Active workspace set to %q\n", args[0])
			return nil
		},
	}
}

func workspaceClient() (*apiclient.Client, error) {
	client, _, err := newAPIClient(workspaceTarget)
	if err != nil {
		return nil, err
	}
	if client.Workspace == "" {
		return nil, fmt.Errorf("no workspace set — use --workspace, set ALGEDONIA_WORKSPACE, or run `%s workspace use <slug>`", commandName())
	}
	return client, nil
}

func printWorkspace(w io.Writer, workspace *apiclient.Workspace) {
	fmt.Fprintf(w, "Slug: %s\n", workspace.Slug)
	fmt.Fprintf(w, "Name: %s\n", workspace.Name)
	fmt.Fprintf(w, "Prefix: %s\n", workspace.Prefix)
	fmt.Fprintf(w, "GitHub repo URL: %s\n", workspaceStringValue(workspace.GitHubRepoURL))
	fmt.Fprintf(w, "Max iterations: %d\n", workspace.MaxIterations)
	fmt.Fprintf(w, "Worktree bootstrap script:\n%s\n", workspaceStringValue(workspace.WorktreeBootstrapScript))
	fmt.Fprintf(w, "Worktree run script:\n%s\n", workspaceStringValue(workspace.WorktreeRunScript))
}

func workspaceStringValue(value *string) string {
	if value == nil || *value == "" {
		return "(empty)"
	}
	return *value
}

func printJSONTo(w io.Writer, v interface{}) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func humanizeWorkspaceAPIError(err error) error {
	apiErr, ok := err.(*apiclient.APIError)
	if !ok {
		return err
	}

	var payload struct {
		Error  string              `json:"error"`
		Errors map[string][]string `json:"errors"`
	}
	if json.Unmarshal([]byte(apiErr.Body), &payload) != nil {
		return err
	}

	if len(payload.Errors) > 0 {
		fields := make([]string, 0, len(payload.Errors))
		for field := range payload.Errors {
			fields = append(fields, field)
		}
		sort.Strings(fields)

		lines := make([]string, 0, len(fields))
		for _, field := range fields {
			label := field
			if flag := workspaceFlagName(field); flag != "" {
				label = fmt.Sprintf("%s (%s)", field, flag)
			}
			lines = append(lines, fmt.Sprintf("%s: %s", label, strings.Join(payload.Errors[field], "; ")))
		}
		return fmt.Errorf("%s", strings.Join(lines, "\n"))
	}

	if strings.TrimSpace(payload.Error) != "" {
		return fmt.Errorf("%s", payload.Error)
	}

	return err
}

func workspaceFlagName(field string) string {
	switch field {
	case "name":
		return "--name"
	case "github_repo_url":
		return "--github-repo-url"
	case "max_iterations":
		return "--max-iterations"
	case "worktree_bootstrap_script":
		return "--worktree-bootstrap-script"
	case "worktree_run_script":
		return "--worktree-run-script"
	default:
		return ""
	}
}

// newAPIClient creates an API client from saved config.
// workspaceOverride takes precedence over the saved workspace.
func newAPIClient(workspaceOverride string) (*apiclient.Client, *config.Config, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}

	if cfg.Token == "" {
		return nil, nil, fmt.Errorf("not logged in — run `%s login` first", commandName())
	}

	baseURL := httpBaseURL(cfg.ServerURL)
	if baseURL == "" {
		baseURL = profileDefaultHTTPBaseURL()
	}

	workspace := strings.TrimSpace(workspaceOverride)
	if workspace == "" {
		workspace = strings.TrimSpace(os.Getenv("ALGEDONIA_WORKSPACE"))
	}
	if workspace == "" {
		workspace = strings.TrimSpace(os.Getenv("ALGEDONIA_WORKSPACE_SLUG"))
	}
	if workspace == "" {
		workspace = cfg.Workspace
	}

	return apiclient.New(baseURL, cfg.Token, workspace), cfg, nil
}
