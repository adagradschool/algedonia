defmodule AlgedoniaWeb.HealthController do
  @moduledoc """
  Minimal health check endpoint for Fly.io machine checks.
  """
  use AlgedoniaWeb, :controller

  @doc "Returns 200 OK with plain text body for health probes."
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
