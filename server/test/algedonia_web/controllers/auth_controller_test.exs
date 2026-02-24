defmodule AlgedoniaWeb.AuthControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  test "GET /auth/github redirects to Supabase OAuth", %{conn: conn} do
    conn = get(conn, ~p"/auth/github")
    location = redirected_to(conn)
    assert location =~ "/auth/v1/authorize"
    assert location =~ "flow_type=pkce"
    assert location =~ "code_challenge="
  end

  test "GET /auth/callback without code redirects to / with flash", %{conn: conn} do
    conn = get(conn, ~p"/auth/callback")
    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing"
  end

  test "DELETE /auth/logout clears session and redirects to /", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{user_id: 1})
      |> delete(~p"/auth/logout")

    assert redirected_to(conn) == "/"
  end
end
