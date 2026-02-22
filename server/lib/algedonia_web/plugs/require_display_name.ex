defmodule AlgedoniaWeb.Plugs.RequireDisplayName do
  @moduledoc """
  Deprecated. Use RequireUser instead.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :user_id) do
      conn
    else
      conn
      |> put_flash(:error, "Please run `ag connect` to join a workspace.")
      |> redirect(to: "/")
      |> halt()
    end
  end
end
