defmodule AlgedoniaWeb.PageController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Accounts
  alias Algedonia.TenantScope
  alias Algedonia.Tickets
  alias Algedonia.Workspaces

  def home(conn, _params) do
    case get_session(conn, :user_id) do
      nil ->
        render(conn, :landing, layout: false)

      user_id ->
        user_id
        |> Accounts.list_workspaces_for_user()
        |> redirect_for_workspaces(conn)
    end
  end

  defp redirect_for_workspaces([], conn), do: redirect(conn, to: ~p"/onboarding")

  defp redirect_for_workspaces([workspace | _], conn) do
    has_tickets? =
      TenantScope.with_workspace(workspace.id, fn ->
        Tickets.list_tickets(workspace_id: workspace.id) != []
      end)

    if has_tickets? do
      redirect(conn, to: ~p"/w/#{workspace.slug}/tickets")
    else
      redirect(conn, to: ~p"/onboarding")
    end
  end

  def workspace_home(conn, %{"workspace" => workspace}) do
    current_workspace = Workspaces.get_workspace_by_slug!(workspace)

    conn
    |> assign(:current_scope, nil)
    |> assign(:current_path, conn.request_path)
    |> assign(:nav_section, :inbox)
    |> assign(:current_workspace, current_workspace)
    |> assign(:current_user, load_current_user(conn))
    |> render(:home)
  end

  defp load_current_user(conn) do
    case get_session(conn, :user_id) do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end
end
