defmodule Algedonia.Repo.Migrations.CreateInlineReviews do
  use Ecto.Migration

  def change do
    create table(:inline_reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :loop_id, references(:loops, type: :binary_id, on_delete: :delete_all), null: false
      add :author, :string, null: false
      add :file_path, :string, null: false
      add :line_number, :integer, null: false
      add :diff_hunk, :text, null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:inline_reviews, [:loop_id])

    execute(
      "ALTER TABLE inline_reviews ADD CONSTRAINT inline_reviews_status_check CHECK (status IN ('pending', 'addressed', 'resolved'))",
      "ALTER TABLE inline_reviews DROP CONSTRAINT inline_reviews_status_check"
    )
  end
end
