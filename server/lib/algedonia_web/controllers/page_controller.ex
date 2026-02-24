defmodule AlgedoniaWeb.PageController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Accounts
  alias Algedonia.Workspaces

  def home(conn, _params) do
    case get_session(conn, :user_id) do
      nil ->
        render(conn, :landing, layout: false)

      user_id ->
        workspaces = Accounts.list_workspaces_for_user(user_id)

        case workspaces do
          [workspace | _] ->
            redirect(conn, to: ~p"/w/#{workspace.slug}/tickets")

          [] ->
            redirect(conn, to: ~p"/onboarding")
        end
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
