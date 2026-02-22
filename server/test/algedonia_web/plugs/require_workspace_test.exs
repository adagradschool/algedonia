defmodule AlgedoniaWeb.Plugs.RequireWorkspaceTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias AlgedoniaWeb.Plugs.RequireWorkspace

  import Algedonia.Factory

  test "loads workspace and assigns it when member", %{conn: conn} do
    workspace = insert_workspace!(%{slug: "acme"})
    user = insert_user!()
    _membership = insert_membership!(workspace, user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> Phoenix.Controller.fetch_flash()
      |> Map.put(:params, %{"workspace" => "acme"})
      |> RequireWorkspace.call([])

    assert conn.assigns.current_workspace.id == workspace.id
    assert get_session(conn, :current_workspace_id) == workspace.id
  end

  test "rejects access when not a member", %{conn: conn} do
    _workspace = insert_workspace!(%{slug: "acme"})
    user = insert_user!()

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_id: user.id})
      |> Phoenix.Controller.fetch_flash()
      |> Map.put(:params, %{"workspace" => "acme"})
      |> RequireWorkspace.call([])

    assert conn.halted
  end
end
