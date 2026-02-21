defmodule Algedonia.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false
      add :parent_id, references(:comments, type: :binary_id, on_delete: :nilify_all)
      add :author, :text, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:comments, [:ticket_id])
    create index(:comments, [:parent_id])
  end
end
