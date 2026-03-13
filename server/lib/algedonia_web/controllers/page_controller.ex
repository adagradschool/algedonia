defmodule AlgedoniaWeb.PageController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Accounts
  alias Algedonia.TenantScope
  alias Algedonia.Tickets

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
end
