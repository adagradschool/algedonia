defmodule Algedonia.Repo.Migrations.AddGithubAuth do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :github_id, :bigint
      add :github_username, :text
      add :avatar_url, :text
    end

    create unique_index(:users, [:github_id])

    alter table(:workspaces) do
      remove :invite_token, :text, null: false
    end
  end
end
