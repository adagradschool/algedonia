defmodule AlgedoniaWeb.Plugs.RequireUser do
  @moduledoc """
  Loads the current user from the session and assigns it to the conn.
  Redirects to home when no user session is present.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Algedonia.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> put_flash(:error, "Please sign in to continue.")
        |> redirect(to: "/")
        |> halt()

      user_id ->
        case Accounts.get_user(user_id) do
          nil ->
            conn
            |> configure_session(drop: true)
            |> put_flash(:error, "Please sign in to continue.")
            |> redirect(to: "/")
            |> halt()

          user ->
            assign(conn, :current_user, user)
        end
    end
  end
end
