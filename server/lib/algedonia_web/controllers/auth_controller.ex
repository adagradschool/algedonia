defmodule AlgedoniaWeb.AuthController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Accounts
  alias Algedonia.Workspaces

  def create(conn, %{"name" => name, "token" => token}) when is_binary(name) and name != "" do
    case Workspaces.get_workspace_by_invite_token(token) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> put_view(AlgedoniaWeb.AuthHTML)
        |> render(:error, message: "Invalid invite token.")

      workspace ->
        with {:ok, user} <- Accounts.get_or_create_user(%{name: name}) do
          _ = Workspaces.ensure_membership(workspace, user)

          conn
          |> put_session(:display_name, name)
          |> put_session(:user_id, user.id)
          |> put_session(:current_workspace_id, workspace.id)
          |> redirect(to: ~p"/w/#{workspace.slug}/tickets")
        end
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(AlgedoniaWeb.AuthHTML)
    |> render(:error, message: "Missing name or token.")
  end
end
