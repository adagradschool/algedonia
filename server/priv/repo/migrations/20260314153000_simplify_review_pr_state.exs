defmodule Algedonia.Repo.Migrations.SimplifyReviewPrState do
  use Ecto.Migration

  def change do
    alter table(:loops) do
      remove :branch_name, :text
    end

    alter table(:tickets) do
      remove :review_pr_url, :string
      remove :review_last_activity_at, :utc_datetime_usec
      remove :review_paused, :boolean
    end
  end
end
