defmodule AlgedoniaWeb.PageController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Workspaces

  def home(conn, _params) do
    current_workspace_slug = get_session(conn, :current_workspace_slug)

    current_workspace =
      if current_workspace_slug do
        Workspaces.get_workspace_by_slug!(current_workspace_slug)
      else
        nil
      end

    conn
    |> assign(:current_scope, nil)
    |> assign(:current_path, conn.request_path)
    |> assign(:nav_section, :inbox)
    |> assign(:current_workspace, current_workspace)
    |> render(:home)
  end

  def workspace_home(conn, %{"workspace" => workspace}) do
    current_workspace = Workspaces.get_workspace_by_slug!(workspace)

    conn
    |> assign(:current_scope, nil)
    |> assign(:current_path, conn.request_path)
    |> assign(:nav_section, :inbox)
    |> assign(:current_workspace, current_workspace)
    |> render(:home)
  end
end
