defmodule AlgedoniaWeb.Plugs.ApiAuth do
  @moduledoc """
  Validates daemon auth tokens from the Authorization header for API endpoints.
  Expects `Bearer <token>` where the token was issued via Phoenix.Token during device flow.
  """
  import Plug.Conn

  alias Algedonia.Accounts

  @max_age 7 * 86_400

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{user_id: user_id}} <-
           Phoenix.Token.verify(AlgedoniaWeb.Endpoint, "daemon_auth", token, max_age: @max_age),
         %{} = user <- Accounts.get_user(user_id) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "invalid or missing token"})
        |> halt()
    end
  end
end
