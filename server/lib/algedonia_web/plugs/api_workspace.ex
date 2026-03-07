defmodule AlgedoniaWeb.Plugs.ApiWorkspace do
  @moduledoc """
  Resolves the workspace from the `:workspace` path param and assigns it.
  Returns 404 if the workspace is not found or the user lacks membership.
  """
  import Plug.Conn

  alias Algedonia.Workspaces

  def init(opts), do: opts

  def call(%{params: %{"workspace" => slug}} = conn, _opts) do
    user = conn.assigns[:current_user]

    with {:ok, workspace} <- fetch_workspace(slug),
         true <- has_membership?(workspace.id, user.id) do
      Algedonia.TenantScope.put_workspace(workspace.id)
      assign(conn, :workspace, workspace)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.json(%{error: "workspace not found"})
        |> halt()
    end
  end

  defp fetch_workspace(slug) do
    {:ok, Workspaces.get_workspace_by_slug!(slug)}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp has_membership?(workspace_id, user_id) do
    Workspaces.get_membership(workspace_id, user_id) != nil
  end
end
