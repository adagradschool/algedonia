defmodule Algedonia.Repo.Migrations.AddGithubAuth do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :github_id, :bigint
      add :github_username, :text
      add :avatar_url, :text
    end

    create unique_index(:users, [:github_id])

    drop_if_exists index(:workspaces, [:invite_token])
    execute "ALTER TABLE workspaces DROP COLUMN IF EXISTS invite_token"
  end

  def down do
    alter table(:users) do
      remove :github_id
      remove :github_username
      remove :avatar_url
    end

    drop_if_exists index(:users, [:github_id])

    alter table(:workspaces) do
      add :invite_token, :text
    end

    create_if_not_exists unique_index(:workspaces, [:invite_token])
  end
end
