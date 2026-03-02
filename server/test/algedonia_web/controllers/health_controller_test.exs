defmodule AlgedoniaWeb.HealthControllerTest do
  use AlgedoniaWeb.ConnCase

  test "GET /health returns 200 ok", %{conn: _conn} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> get(~p"/health")

    assert response(conn, 200) == "ok"
    assert response_content_type(conn, :text) =~ "text/plain"
  end
end
