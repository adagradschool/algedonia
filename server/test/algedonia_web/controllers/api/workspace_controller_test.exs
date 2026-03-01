defmodule AlgedoniaWeb.Api.WorkspaceControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  describe "GET /api/workspaces" do
    test "returns 200 with workspace list for authenticated user", %{
      user: user,
      workspace: workspace
    } do
      token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/workspaces")

      assert %{"workspaces" => workspaces} = json_response(conn, 200)
      assert workspaces != []

      ws = Enum.find(workspaces, &(&1["id"] == workspace.id))
      assert ws["name"] == workspace.name
      assert ws["slug"] == workspace.slug
      assert ws["prefix"] == workspace.prefix
    end

    test "returns 401 for unauthenticated request" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> get("/api/workspaces")

      assert json_response(conn, 401)["error"] =~ "invalid or missing token"
    end

    test "returns empty list for user with no workspaces" do
      # Create a user with no workspace memberships
      user_no_ws = Algedonia.Factory.insert_user!(%{name: "lonely"})
      token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user_no_ws.id})

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/workspaces")

      assert %{"workspaces" => []} = json_response(conn, 200)
    end
  end
end
