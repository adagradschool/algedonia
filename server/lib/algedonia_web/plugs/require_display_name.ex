defmodule AlgedoniaWeb.Plugs.RequireDisplayName do
  @moduledoc """
  Redirects to the home page when no display name is set in the session.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :display_name) do
      conn
    else
      conn
      |> put_flash(:error, "Please run `ag connect` to set your display name.")
      |> redirect(to: "/")
      |> halt()
    end
  end
end
