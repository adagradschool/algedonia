defmodule Algedonia.WorkspacesSettingsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Workspaces
  alias Algedonia.Workspaces.WorkspaceInvitation

  import Algedonia.Factory

  describe "change_workspace/2" do
    test "returns a changeset for to_form" do
      workspace = default_workspace!()
      changeset = Workspaces.change_workspace(workspace)
      assert %Ecto.Changeset{} = changeset
    end
  end

  describe "update_workspace/2" do
    test "updates name, slug, prefix, github_repo_url, and max_iterations" do
      workspace = insert_workspace!(%{name: "Old Name"})

      assert {:ok, updated} =
               Workspaces.update_workspace(workspace, %{
                 name: "New Name",
                 slug: "new-name",
                 prefix: "NEW",
                 github_repo_url: "https://github.com/org/repo",
                 max_iterations: 8
               })

      assert updated.name == "New Name"
      assert updated.slug == "new-name"
      assert updated.prefix == "NEW"
      assert updated.github_repo_url == "https://github.com/org/repo"
      assert updated.max_iterations == 8
    end

    test "rejects invalid github_repo_url" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Workspaces.update_workspace(workspace, %{github_repo_url: "not-a-url"})

      assert errors_on(changeset).github_repo_url
    end

    test "rejects duplicate slug" do
      _existing = insert_workspace!(%{slug: "taken"})
      workspace = insert_workspace!()

      assert {:error, changeset} = Workspaces.update_workspace(workspace, %{slug: "taken"})
      assert errors_on(changeset).slug
    end

    test "rejects invalid max_iterations" do
      workspace = insert_workspace!()

      assert {:error, changeset} = Workspaces.update_workspace(workspace, %{max_iterations: 0})
      assert errors_on(changeset).max_iterations
    end
  end

  describe "list_members/1" do
    test "returns users who are members of the workspace" do
      workspace = insert_workspace!()
      user = insert_user!(%{name: "Alice"})
      insert_membership!(workspace, user)

      members = Workspaces.list_members(workspace.id)
      assert length(members) == 1
      assert hd(members).name == "Alice"
    end

    test "returns empty list for workspace with no members" do
      workspace = insert_workspace!()
      assert Workspaces.list_members(workspace.id) == []
    end
  end

  describe "remove_member/2" do
    test "removes an existing membership" do
      workspace = insert_workspace!()
      user = insert_user!()
      insert_membership!(workspace, user)

      assert {:ok, _} = Workspaces.remove_member(workspace.id, user.id)
      assert Workspaces.get_membership(workspace.id, user.id) == nil
    end

    test "returns error for non-existent membership" do
      assert {:error, :not_found} =
               Workspaces.remove_member(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "create_invitation/3" do
    test "creates a pending invitation with lowercased username" do
      workspace = insert_workspace!()
      user = insert_user!()

      assert {:ok, invitation} = Workspaces.create_invitation(workspace, "AliceGH", user)
      assert invitation.github_username == "alicegh"
      assert invitation.status == :pending
      assert invitation.workspace_id == workspace.id
      assert invitation.invited_by_id == user.id
    end

    test "rejects duplicate pending invitation" do
      workspace = insert_workspace!()
      user = insert_user!()

      assert {:ok, _} = Workspaces.create_invitation(workspace, "alice", user)
      assert {:error, changeset} = Workspaces.create_invitation(workspace, "alice", user)
      assert errors_on(changeset).workspace_id
    end
  end

  describe "list_invitations/1" do
    test "returns pending invitations with invited_by preloaded" do
      workspace = insert_workspace!()
      user = insert_user!()
      {:ok, _} = Workspaces.create_invitation(workspace, "bob", user)

      invitations = Workspaces.list_invitations(workspace.id)
      assert length(invitations) == 1
      assert hd(invitations).github_username == "bob"
      assert hd(invitations).invited_by.id == user.id
    end

    test "excludes cancelled invitations" do
      workspace = insert_workspace!()
      user = insert_user!()
      {:ok, invitation} = Workspaces.create_invitation(workspace, "bob", user)
      Workspaces.cancel_invitation(invitation.id)

      assert Workspaces.list_invitations(workspace.id) == []
    end
  end

  describe "cancel_invitation/1" do
    test "sets invitation status to cancelled" do
      workspace = insert_workspace!()
      user = insert_user!()
      {:ok, invitation} = Workspaces.create_invitation(workspace, "bob", user)

      assert {:ok, cancelled} = Workspaces.cancel_invitation(invitation.id)
      assert cancelled.status == :cancelled
    end
  end

  describe "accept_pending_invitations/1" do
    test "accepts matching invitations and creates memberships" do
      workspace = insert_workspace!()
      inviter = insert_user!()
      {:ok, _} = Workspaces.create_invitation(workspace, "newuser", inviter)

      user = insert_user!(%{github_username: "newuser"})
      assert {:ok, 1} = Workspaces.accept_pending_invitations(user)
      assert Workspaces.get_membership(workspace.id, user.id)

      # Invitation should now be accepted
      [invitation] =
        Algedonia.Repo.all(
          from(i in WorkspaceInvitation,
            where: i.workspace_id == ^workspace.id and i.github_username == "newuser"
          )
        )

      assert invitation.status == :accepted
    end

    test "returns 0 for user with no pending invitations" do
      user = insert_user!(%{github_username: "nobody"})
      assert {:ok, 0} = Workspaces.accept_pending_invitations(user)
    end

    test "returns 0 for user with nil github_username" do
      user = insert_user!()
      assert {:ok, 0} = Workspaces.accept_pending_invitations(user)
    end

    test "handles case-insensitive matching" do
      workspace = insert_workspace!()
      inviter = insert_user!()
      {:ok, _} = Workspaces.create_invitation(workspace, "CamelCase", inviter)

      user = insert_user!(%{github_username: "camelcase"})
      assert {:ok, 1} = Workspaces.accept_pending_invitations(user)
    end
  end
end
