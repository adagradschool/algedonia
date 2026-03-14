defmodule AlgedoniaWeb.Api.WorkspaceControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias Algedonia.Workspaces

  describe "GET /api/workspaces" do
    test "returns 200 with workspace list and orchestration fields for authenticated user", %{
      user: user,
      workspace: workspace
    } do
      {:ok, workspace} =
        Workspaces.update_workspace(workspace, %{
          github_repo_url: "https://github.com/example/algedonia",
          worktree_bootstrap_script: "scripts/bootstrap.sh",
          tracker_config: %{"planning_states" => ["planning", "ready"]},
          playback_config: %{"concurrency" => 2},
          defaults: %{"base_pipeline" => ["compile", "test", "lint"]},
          max_iterations: 7,
          planning_mode: :always_approve
        })

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
      assert ws["github_repo_url"] == workspace.github_repo_url
      assert ws["worktree_bootstrap_script"] == workspace.worktree_bootstrap_script
      assert ws["tracker_config"] == workspace.tracker_config
      assert ws["playback_config"] == workspace.playback_config
      assert ws["defaults"] == workspace.defaults
      assert ws["max_iterations"] == workspace.max_iterations
      assert ws["planning_mode"] == "always_approve"
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
