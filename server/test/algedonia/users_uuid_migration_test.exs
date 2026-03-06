defmodule Algedonia.UsersUuidMigrationTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Factory
  alias Algedonia.Workspaces.WorkspaceInvitation
  alias Algedonia.Workspaces.WorkspaceMembership
  alias Ecto.Adapters.SQL

  test "user identity columns are UUID and linked foreign keys are UUID" do
    assert column_type("users", "id") == "uuid"
    assert column_type("workspace_memberships", "user_id") == "uuid"
    assert column_type("workspace_invitations", "invited_by_id") == "uuid"
  end

  test "membership and invitation foreign keys still enforce user referential integrity" do
    workspace = Factory.insert_workspace!()
    user = Factory.insert_user!(%{github_id: 5050, github_username: "fk-user"})

    membership =
      %WorkspaceMembership{}
      |> WorkspaceMembership.changeset(%{
        workspace_id: workspace.id,
        user_id: user.id,
        role: :member
      })
      |> Repo.insert!()

    invitation =
      %WorkspaceInvitation{}
      |> WorkspaceInvitation.changeset(%{
        workspace_id: workspace.id,
        invited_by_id: user.id,
        github_username: "invitee"
      })
      |> Repo.insert!()

    assert {:ok, _uuid} = Ecto.UUID.cast(membership.user_id)
    assert {:ok, _uuid} = Ecto.UUID.cast(invitation.invited_by_id)

    Repo.delete!(user)

    assert Repo.get(WorkspaceMembership, membership.id) == nil
    assert Repo.get(WorkspaceInvitation, invitation.id) == nil
  end

  defp column_type(table, column) do
    %{rows: [[type]]} =
      SQL.query!(
        Repo,
        """
        SELECT data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    type
  end
end
