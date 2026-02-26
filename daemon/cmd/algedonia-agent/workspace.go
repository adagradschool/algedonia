package main

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/algedonia/daemon/internal/apiclient"
	"github.com/algedonia/daemon/internal/config"
	"github.com/spf13/cobra"
)

func newWorkspaceCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "workspace",
		Aliases: []string{"ws"},
		Short:   "Manage workspaces",
	}

	cmd.AddCommand(newWorkspaceListCmd())
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
				fmt.Fprintln(os.Stderr, "No workspaces found.")
				return nil
			}

			w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
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

			fmt.Printf("Active workspace set to %q\n", args[0])
			return nil
		},
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
		return nil, nil, fmt.Errorf("not logged in — run `ag login` first")
	}

	baseURL := httpBaseURL(cfg.ServerURL)
	if baseURL == "" {
		baseURL = "http://localhost:4000"
	}

	workspace := workspaceOverride
	if workspace == "" {
		workspace = cfg.Workspace
	}

	return apiclient.New(baseURL, cfg.Token, workspace), cfg, nil
}
