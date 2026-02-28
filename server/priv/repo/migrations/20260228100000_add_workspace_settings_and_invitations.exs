defmodule Algedonia.Repo.Migrations.AddWorkspaceSettingsAndInvitations do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :github_repo_url, :text
    end

    create table(:workspace_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :github_username, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :invited_by_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:workspace_invitations, [:workspace_id])
    create index(:workspace_invitations, [:github_username])

    create unique_index(:workspace_invitations, [:workspace_id, :github_username],
             where: "status = 'pending'",
             name: :workspace_invitations_pending_unique
           )

    execute(
      "ALTER TABLE workspace_invitations ADD CONSTRAINT workspace_invitations_status_check CHECK (status IN ('pending', 'accepted', 'cancelled'))",
      "ALTER TABLE workspace_invitations DROP CONSTRAINT workspace_invitations_status_check"
    )
  end
end
