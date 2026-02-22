defmodule AlgedoniaWeb.AuthControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  describe "GET /auth" do
    test "sets session and redirects with valid token", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> get(~p"/auth?name=Ada&token=test-token")

      assert redirected_to(conn) == ~p"/tickets"
      assert get_session(conn, :display_name) == "Ada"
    end

    test "returns 401 with invalid token", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> get(~p"/auth?name=Ada&token=wrong-token")

      assert conn.status == 401
      assert conn.resp_body =~ "Authentication Failed"
    end

    test "returns 400 without params", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> get(~p"/auth")

      assert conn.status == 400
      assert conn.resp_body =~ "Missing name or token"
    end
  end
end
