defmodule AlgedoniaWeb.Api.TerminalController do
  use AlgedoniaWeb, :controller

  alias AlgedoniaWeb.TerminalAccessToken

  def verify(conn, %{"token" => token, "loop_id" => loop_id}) do
    current_user = conn.assigns.current_user

    with {:ok, claims} <- TerminalAccessToken.verify(token, max_age: 600),
         true <- to_string(claim(claims, :user_id)) == to_string(current_user.id),
         true <- to_string(claim(claims, :loop_id)) == to_string(loop_id) do
      json(conn, %{ok: true})
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_terminal_token"})
    end
  end

  def verify(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing token or loop_id"})
  end

  defp claim(claims, key) when is_map(claims) and is_atom(key) do
    Map.get(claims, key) || Map.get(claims, Atom.to_string(key))
  end
end
