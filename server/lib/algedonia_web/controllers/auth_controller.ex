defmodule AlgedoniaWeb.AuthController do
  use AlgedoniaWeb, :controller

  def create(conn, %{"name" => name, "token" => token}) when is_binary(name) and name != "" do
    expected = Application.get_env(:algedonia, :project_token)

    if Plug.Crypto.secure_compare(token, expected) do
      conn
      |> put_session(:display_name, name)
      |> redirect(to: ~p"/tickets")
    else
      conn
      |> put_status(:unauthorized)
      |> put_view(AlgedoniaWeb.AuthHTML)
      |> render(:error, message: "Invalid token.")
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(AlgedoniaWeb.AuthHTML)
    |> render(:error, message: "Missing name or token.")
  end
end
