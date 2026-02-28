defmodule Algedonia.WorkspacesTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Repo
  alias Algedonia.Workspaces

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
  end
end
