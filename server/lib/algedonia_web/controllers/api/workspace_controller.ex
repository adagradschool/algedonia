defmodule AlgedoniaWeb.Api.WorkspaceController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Accounts

  def index(conn, _params) do
    user = conn.assigns.current_user
    workspaces = Accounts.list_workspaces_for_user(user.id)

    json(conn, %{
      workspaces:
        Enum.map(workspaces, fn w ->
          %{
            id: w.id,
            name: w.name,
            slug: w.slug,
            prefix: w.prefix,
            github_repo_url: w.github_repo_url,
            worktree_bootstrap_script: w.worktree_bootstrap_script,
            worktree_run_script: w.worktree_run_script,
            tracker_config: w.tracker_config,
            playback_config: w.playback_config,
            defaults: w.defaults,
            max_iterations: w.max_iterations,
            planning_mode: w.planning_mode
          }
        end)
    })
  end
end
