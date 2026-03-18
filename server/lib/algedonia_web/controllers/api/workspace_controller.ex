defmodule AlgedoniaWeb.Api.WorkspaceController do
  use AlgedoniaWeb, :controller

  import AlgedoniaWeb.Helpers, only: [slugify: 1]

  alias Algedonia.{Accounts, Workspaces}

  @editable_fields ~w(name github_repo_url max_iterations worktree_bootstrap_script worktree_run_script)

  def index(conn, _params) do
    user = conn.assigns.current_user
    workspaces = Accounts.list_workspaces_for_user(user.id)

    json(conn, %{
      workspaces: Enum.map(workspaces, &serialize_workspace/1)
    })
  end

  def show(conn, _params) do
    json(conn, %{workspace: serialize_workspace(conn.assigns.workspace)})
  end

  def update(conn, _params) do
    case conn.body_params["workspace"] do
      attrs when is_map(attrs) ->
        workspace = conn.assigns.workspace

        attrs =
          attrs
          |> Map.take(@editable_fields)
          |> derive_workspace_identity(workspace)

        case Workspaces.update_workspace(workspace, attrs) do
          {:ok, updated} ->
            json(conn, %{workspace: serialize_workspace(updated)})

          {:error, changeset} ->
            conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
        end

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "missing workspace params"})
    end
  end

  defp derive_workspace_identity(attrs, workspace) do
    name = Map.get(attrs, "name", workspace.name)

    attrs
    |> Map.put("slug", slugify(name))
    |> Map.put("prefix", Workspaces.prefix_for_name(name))
  end

  defp serialize_workspace(workspace) do
    %{
      id: workspace.id,
      name: workspace.name,
      slug: workspace.slug,
      prefix: workspace.prefix,
      github_repo_url: workspace.github_repo_url,
      worktree_bootstrap_script: workspace.worktree_bootstrap_script,
      worktree_run_script: workspace.worktree_run_script,
      tracker_config: workspace.tracker_config,
      playback_config: workspace.playback_config,
      defaults: workspace.defaults,
      max_iterations: workspace.max_iterations,
      planning_mode: workspace.planning_mode
    }
  end

  defp format_errors(changeset), do: AlgedoniaWeb.Helpers.format_errors(changeset)
end
