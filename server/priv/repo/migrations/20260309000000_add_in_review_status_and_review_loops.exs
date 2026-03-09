defmodule Algedonia.Repo.Migrations.AddInReviewStatusAndReviewLoops do
  use Ecto.Migration

  def up do
    # Expand ticket status CHECK to include 'in_review'
    execute("ALTER TABLE tickets DROP CONSTRAINT IF EXISTS valid_status")

    execute(
      "ALTER TABLE tickets ADD CONSTRAINT valid_status CHECK (status IN ('backlog', 'planning', 'halted', 'in_progress', 'in_review', 'completed', 'archived'))"
    )

    # Expand loop role CHECK to include 'review'
    execute("ALTER TABLE loops DROP CONSTRAINT IF EXISTS loops_role_check")

    execute(
      "ALTER TABLE loops ADD CONSTRAINT loops_role_check CHECK (role IN ('task', 'hook', 'planning', 'review'))"
    )

    # Expand loop_steps role CHECK to include 'review'
    execute("ALTER TABLE loop_steps DROP CONSTRAINT IF EXISTS loop_steps_role_check")

    execute(
      "ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_role_check CHECK (role IN ('maker', 'checker', 'hook', 'planning', 'review'))"
    )

    # Add review-specific fields to tickets
    alter table(:tickets) do
      add :review_pr_number, :integer
      add :review_pr_url, :string
      add :review_last_activity_at, :utc_datetime_usec
      add :review_paused, :boolean, default: false, null: false
    end
  end

  def down do
    alter table(:tickets) do
      remove :review_pr_number
      remove :review_pr_url
      remove :review_last_activity_at
      remove :review_paused
    end

    execute("ALTER TABLE loop_steps DROP CONSTRAINT IF EXISTS loop_steps_role_check")

    execute(
      "ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_role_check CHECK (role IN ('maker', 'checker', 'hook', 'planning'))"
    )

    execute("ALTER TABLE loops DROP CONSTRAINT IF EXISTS loops_role_check")

    execute(
      "ALTER TABLE loops ADD CONSTRAINT loops_role_check CHECK (role IN ('task', 'hook', 'planning'))"
    )

    execute("ALTER TABLE tickets DROP CONSTRAINT IF EXISTS valid_status")

    execute(
      "ALTER TABLE tickets ADD CONSTRAINT valid_status CHECK (status IN ('backlog', 'planning', 'halted', 'in_progress', 'completed', 'archived'))"
    )
  end
end
