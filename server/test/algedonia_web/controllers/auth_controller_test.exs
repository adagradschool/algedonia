defmodule AlgedoniaWeb.AuthControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias Algedonia.Accounts
  alias Algedonia.Workspaces

  import Algedonia.Factory

  test "connect with invite token creates membership and redirects", %{conn: conn} do
    workspace = insert_workspace!(%{slug: "acme", invite_token: "token-123"})

    conn = get(conn, ~p"/auth", %{name: "Ada", token: "token-123"})

    assert redirected_to(conn) == "/w/acme/tickets"

    user = Accounts.get_user_by_name("Ada")
    assert user
    assert Workspaces.get_membership(workspace.id, user.id)
  end
end
