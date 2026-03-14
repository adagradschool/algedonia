defmodule Algedonia.WorkspacesTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Repo
  alias Algedonia.Workspaces
  alias Algedonia.Workspaces.WorkspaceMembership

  import Algedonia.Factory

  describe "prefix_for_name/1" do
    test "defaults to first three letters" do
      assert Workspaces.prefix_for_name("Acme Labs") == "ACM"
    end

    test "falls back to AG when empty" do
      assert Workspaces.prefix_for_name("123 !") == "AG"
    end
  end

  describe "next_ticket_number!/1" do
    test "increments per workspace" do
      workspace = insert_workspace!(%{next_ticket_number: 1})

      assert Workspaces.next_ticket_number!(workspace) == 1
      assert Workspaces.next_ticket_number!(workspace) == 2

      reloaded = Repo.get!(Algedonia.Workspaces.Workspace, workspace.id)
      assert reloaded.next_ticket_number == 3
    end
  end

  describe "get_workspace_by_slug/1" do
    test "returns workspace when found" do
      workspace = insert_workspace!(%{slug: "find-me"})
      found = Workspaces.get_workspace_by_slug("find-me")
      assert found.id == workspace.id
    end

    test "returns nil when not found" do
      assert Workspaces.get_workspace_by_slug("nonexistent") == nil
    end
  end

  describe "ensure_membership/2" do
    test "creates membership if missing and is idempotent" do
      workspace = default_workspace!()
      user = insert_user!()

      assert {:ok, _} = Workspaces.ensure_membership(workspace, user)
      assert {:ok, _} = Workspaces.ensure_membership(workspace, user)

      assert Workspaces.get_membership(workspace.id, user.id)
    end

    test "allows creating an owner membership" do
      workspace = default_workspace!()
      user = insert_user!()

      assert {:ok, membership} = Workspaces.ensure_membership(workspace, user, role: :owner)
      assert membership.role == :owner
    end
  end

  describe "workspace config fields" do
    test "persists tracker/playback/defaults, max_iterations, planning mode, and worktree scripts" do
      attrs = %{
        name: "Acme",
        slug: "acme-ws",
        prefix: "ACM",
        github_repo_url: "https://github.com/acme/repo",
        worktree_bootstrap_script: "bin/setup-worktree",
        worktree_run_script: "bin/verify-worktree",
        tracker_config: %{"planning_states" => ["planning"]},
        playback_config: %{"concurrency" => 2},
        defaults: %{"base_pipeline" => ["compile", "test", "lint"]},
        max_iterations: 7,
        planning_mode: :always_review
      }

      assert {:ok, workspace} = Workspaces.create_workspace(attrs)
      assert workspace.tracker_config == %{"planning_states" => ["planning"]}
      assert workspace.playback_config == %{"concurrency" => 2}
      assert workspace.defaults == %{"base_pipeline" => ["compile", "test", "lint"]}
      assert workspace.max_iterations == 7
      assert workspace.planning_mode == :always_review
      assert workspace.worktree_bootstrap_script == "bin/setup-worktree"
      assert workspace.worktree_run_script == "bin/verify-worktree"
    end

    test "updates tracker/playback/defaults, max_iterations, planning mode, and worktree scripts" do
      workspace = insert_workspace!()

      assert {:ok, updated} =
               Workspaces.update_workspace(workspace, %{
                 worktree_bootstrap_script: "scripts/bootstrap.sh",
                 worktree_run_script: "scripts/verify.sh",
                 tracker_config: %{"planning_states" => ["ready"]},
                 playback_config: %{"concurrency" => 4},
                 defaults: %{"coding_agent" => "codex"},
                 max_iterations: 9,
                 planning_mode: :always_approve
               })

      assert updated.tracker_config == %{"planning_states" => ["ready"]}
      assert updated.playback_config == %{"concurrency" => 4}
      assert updated.defaults == %{"coding_agent" => "codex"}
      assert updated.max_iterations == 9
      assert updated.planning_mode == :always_approve
      assert updated.worktree_bootstrap_script == "scripts/bootstrap.sh"
      assert updated.worktree_run_script == "scripts/verify.sh"
    end

    test "rejects invalid planning mode in changeset" do
      attrs = %{
        name: "Acme",
        slug: "acme-invalid-planning",
        prefix: "ACM",
        planning_mode: :invalid_mode
      }

      assert {:error, changeset} = Workspaces.create_workspace(attrs)
      assert errors_on(changeset).planning_mode
    end

    test "rejects invalid max_iterations in changeset" do
      attrs = %{
        name: "Acme",
        slug: "acme-invalid-iterations",
        prefix: "ACM",
        max_iterations: 0
      }

      assert {:error, changeset} = Workspaces.create_workspace(attrs)
      assert errors_on(changeset).max_iterations
    end
  end

  describe "iteration_budget/1" do
    test "returns configured workspace max_iterations" do
      workspace = insert_workspace!(%{max_iterations: 6})
      assert Workspaces.iteration_budget(workspace) == 6
      assert Workspaces.iteration_budget(workspace.id) == 6
    end

    test "falls back to safe default for missing workspace" do
      assert Workspaces.iteration_budget(Ecto.UUID.generate()) ==
               Workspaces.default_iteration_budget()
    end
  end

  describe "workspace and membership database constraints" do
    test "database rejects invalid planning_mode" do
      assert_raise Postgrex.Error, ~r/workspaces_planning_mode_check/, fn ->
        Repo.query!(
          """
          INSERT INTO workspaces (id, name, slug, prefix, next_ticket_number, planning_mode, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            "Acme Invalid",
            "acme-invalid-db",
            "ACM",
            1,
            "manual_only"
          ]
        )
      end
    end

    test "database rejects invalid membership role" do
      workspace = insert_workspace!()
      user = insert_user!()

      assert_raise Postgrex.Error, ~r/valid_role/, fn ->
        Repo.query!(
          """
          INSERT INTO workspace_memberships (id, workspace_id, user_id, role, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, NOW(), NOW())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(workspace.id),
            Ecto.UUID.dump!(user.id),
            "admin"
          ]
        )
      end
    end

    test "workspace_memberships enforces unique workspace_id/user_id" do
      workspace = insert_workspace!()
      user = insert_user!()

      insert_membership!(workspace, user)

      assert {:error, changeset} =
               %WorkspaceMembership{}
               |> WorkspaceMembership.changeset(%{
                 workspace_id: workspace.id,
                 user_id: user.id,
                 role: :member
               })
               |> Repo.insert()

      assert errors_on(changeset).workspace_id
    end
  end
end
