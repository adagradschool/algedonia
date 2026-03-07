defmodule AlgedoniaWeb.Plugs.RequireWorkspace do
  @moduledoc """
  Loads workspace from the slug and ensures membership.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Algedonia.Workspaces

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)
    workspace_slug = conn.params["workspace"]

    workspace =
      case workspace_slug do
        nil -> nil
        slug -> Workspaces.get_workspace_by_slug!(slug)
      end

    cond do
      is_nil(user_id) or is_nil(workspace) ->
        conn
        |> put_flash(:error, "Workspace not found.")
        |> redirect(to: "/")
        |> halt()

      Workspaces.get_membership(workspace.id, user_id) ->
        Algedonia.TenantScope.put_workspace(workspace.id)

        conn
        |> put_session(:current_workspace_id, workspace.id)
        |> put_session(:current_workspace_slug, workspace.slug)
        |> put_session(:current_workspace_prefix, workspace.prefix)
        |> assign(:current_workspace, workspace)

      true ->
        conn
        |> put_flash(:error, "You don't have access to that workspace.")
        |> redirect(to: "/")
        |> halt()
    end
  end
end
