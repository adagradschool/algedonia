defmodule AlgedoniaWeb.PageControllerTest do
  use AlgedoniaWeb.ConnCase

  test "GET / renders landing page when not logged in", %{conn: _conn} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> init_test_session(%{})
      |> get(~p"/")

    assert html_response(conn, 200) =~ "Sign in with GitHub"
  end

  test "GET / redirects to onboarding when logged in with no workspaces", %{conn: conn} do
    user = Algedonia.Factory.insert_user!()

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> get(~p"/")

    assert redirected_to(conn) == "/onboarding"
  end

  test "GET / redirects to workspace when logged in with workspace and tickets", %{conn: conn} do
    user = Algedonia.Factory.insert_user!()
    workspace = Algedonia.Factory.insert_workspace!(%{slug: "myws", name: "My WS"})
    Algedonia.Factory.insert_membership!(workspace, user)
    Algedonia.Factory.insert_ticket!(%{workspace_id: workspace.id, title: "Test ticket"})

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> get(~p"/")

    assert redirected_to(conn) == "/w/myws/tickets"
  end

  test "GET / redirects to onboarding when workspace has no tickets", %{conn: conn} do
    user = Algedonia.Factory.insert_user!()
    workspace = Algedonia.Factory.insert_workspace!(%{slug: "myws", name: "My WS"})
    Algedonia.Factory.insert_membership!(workspace, user)

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> get(~p"/")

    assert redirected_to(conn) == "/onboarding"
  end
end
