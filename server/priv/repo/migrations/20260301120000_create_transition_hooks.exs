defmodule Algedonia.Repo.Migrations.CreateTransitionHooks do
  use Ecto.Migration

  def change do
    create table(:transition_hooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :from_status, :string, null: false
      add :to_status, :string, null: false
      add :instruction, :text, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:transition_hooks, [:workspace_id, :from_status, :to_status])
    create index(:transition_hooks, [:workspace_id])
  end
end
