defmodule AlgedoniaWeb.Api.WorkspaceControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias Algedonia.Workspaces

  defp daemon_token(user) do
    Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})
  end

  describe "GET /api/workspaces" do
    test "returns 200 with workspace list and orchestration fields for authenticated user", %{
      user: user,
      workspace: workspace
    } do
      {:ok, workspace} =
        Workspaces.update_workspace(workspace, %{
          github_repo_url: "https://github.com/example/algedonia",
          worktree_bootstrap_script: "scripts/bootstrap.sh",
          worktree_run_script: "scripts/verify.sh",
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
      assert ws["worktree_run_script"] == workspace.worktree_run_script
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

  describe "GET /api/w/:workspace/workspace" do
    test "returns the current workspace core settings", %{user: user, workspace: workspace} do
      {:ok, workspace} =
        Workspaces.update_workspace(workspace, %{
          github_repo_url: "https://github.com/example/algedonia",
          worktree_bootstrap_script: "scripts/bootstrap.sh",
          worktree_run_script: "scripts/verify.sh",
          tracker_config: %{"planning_states" => ["planning", "ready"]},
          playback_config: %{"concurrency" => 2},
          defaults: %{"base_pipeline" => ["compile", "test", "lint"]},
          max_iterations: 7,
          planning_mode: :always_approve
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{daemon_token(user)}")
        |> get("/api/w/#{workspace.slug}/workspace")

      assert %{"workspace" => ws} = json_response(conn, 200)
      assert ws["id"] == workspace.id
      assert ws["name"] == workspace.name
      assert ws["slug"] == workspace.slug
      assert ws["prefix"] == workspace.prefix
      assert ws["github_repo_url"] == workspace.github_repo_url
      assert ws["worktree_bootstrap_script"] == workspace.worktree_bootstrap_script
      assert ws["worktree_run_script"] == workspace.worktree_run_script
      assert ws["tracker_config"] == workspace.tracker_config
      assert ws["playback_config"] == workspace.playback_config
      assert ws["defaults"] == workspace.defaults
      assert ws["max_iterations"] == workspace.max_iterations
      assert ws["planning_mode"] == "always_approve"
    end
  end

  describe "PATCH /api/w/:workspace/workspace" do
    test "updates core settings, derives slug and prefix from name, and preserves unrelated fields",
         %{
           user: user,
           workspace: workspace
         } do
      {:ok, workspace} =
        Workspaces.update_workspace(workspace, %{
          tracker_config: %{"planning_states" => ["planning"]},
          playback_config: %{"concurrency" => 2},
          defaults: %{"base_pipeline" => ["compile", "test", "lint"]},
          planning_mode: :always_review
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{daemon_token(user)}")
        |> patch("/api/w/#{workspace.slug}/workspace", %{
          workspace: %{
            name: "Renamed Workspace",
            github_repo_url: "https://github.com/example/renamed",
            max_iterations: 9,
            worktree_bootstrap_script: "scripts/bootstrap.sh",
            worktree_run_script: "scripts/verify.sh",
            tracker_config: %{"ignored" => true}
          }
        })

      assert %{"workspace" => ws} = json_response(conn, 200)
      assert ws["name"] == "Renamed Workspace"
      assert ws["slug"] == "renamed-workspace"
      assert ws["prefix"] == Workspaces.prefix_for_name("Renamed Workspace")
      assert ws["github_repo_url"] == "https://github.com/example/renamed"
      assert ws["max_iterations"] == 9
      assert ws["worktree_bootstrap_script"] == "scripts/bootstrap.sh"
      assert ws["worktree_run_script"] == "scripts/verify.sh"
      assert ws["tracker_config"] == %{"planning_states" => ["planning"]}
      assert ws["playback_config"] == %{"concurrency" => 2}
      assert ws["defaults"] == %{"base_pipeline" => ["compile", "test", "lint"]}
      assert ws["planning_mode"] == "always_review"

      reloaded = Workspaces.get_workspace!(workspace.id)
      assert reloaded.slug == "renamed-workspace"
      assert reloaded.prefix == Workspaces.prefix_for_name("Renamed Workspace")
      assert reloaded.tracker_config == %{"planning_states" => ["planning"]}
      assert reloaded.playback_config == %{"concurrency" => 2}
      assert reloaded.defaults == %{"base_pipeline" => ["compile", "test", "lint"]}
      assert reloaded.planning_mode == :always_review
    end

    test "rejects invalid github repo url", %{user: user, workspace: workspace} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{daemon_token(user)}")
        |> patch("/api/w/#{workspace.slug}/workspace", %{
          workspace: %{github_repo_url: "github.com/example/repo"}
        })

      assert %{"errors" => %{"github_repo_url" => [message]}} = json_response(conn, 422)
      assert message =~ "valid URL"
    end

    test "rejects out-of-range max_iterations without mutating persisted values", %{
      user: user,
      workspace: workspace
    } do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{daemon_token(user)}")
        |> patch("/api/w/#{workspace.slug}/workspace", %{
          workspace: %{max_iterations: 99}
        })

      assert %{"errors" => %{"max_iterations" => [message]}} = json_response(conn, 422)
      assert message =~ "less than or equal to 50"

      assert Workspaces.get_workspace!(workspace.id).max_iterations == workspace.max_iterations
    end
  end
end
