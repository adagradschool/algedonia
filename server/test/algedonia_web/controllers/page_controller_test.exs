defmodule AlgedoniaWeb.PageControllerTest do
  use AlgedoniaWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Welcome back"
  end
end
