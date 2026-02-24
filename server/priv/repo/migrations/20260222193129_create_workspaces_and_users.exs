defmodule Algedonia.Repo.Migrations.CreateWorkspacesAndUsers do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add :name, :text, null: false
      add :slug, :text, null: false
      add :prefix, :text, null: false
      add :next_ticket_number, :bigint, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:slug])

    create table(:users) do
      add :name, :text, null: false
      add :email, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:name])

    create table(:workspace_memberships) do
      add :workspace_id, references(:workspaces, type: :id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :id, on_delete: :delete_all), null: false
      add :role, :text, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
  end
end
