defmodule Algedonia.Repo.Migrations.MoveIterationBudgetToWorkspace do
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :max_iterations, :integer, null: false, default: 10
    end

    execute(
      """
      ALTER TABLE workspaces
      ADD CONSTRAINT workspaces_max_iterations_check
      CHECK (max_iterations > 0 AND max_iterations <= 50)
      """,
      "ALTER TABLE workspaces DROP CONSTRAINT IF EXISTS workspaces_max_iterations_check"
    )

    # Migration strategy for legacy tickets.max_attempts:
    # set each workspace budget to the highest per-ticket value in that workspace
    # so no existing ticket silently gets fewer retries after consolidation.
    execute("""
    WITH workspace_budget AS (
      SELECT workspace_id, GREATEST(1, LEAST(50, MAX(max_attempts))) AS max_iterations
      FROM tickets
      WHERE max_attempts IS NOT NULL
      GROUP BY workspace_id
    )
    UPDATE workspaces w
    SET max_iterations = wb.max_iterations
    FROM workspace_budget wb
    WHERE w.id = wb.workspace_id
    """)

    alter table(:tickets) do
      remove :max_attempts
    end
  end

  def down do
    alter table(:tickets) do
      add :max_attempts, :integer, default: 10
    end

    execute("""
    UPDATE tickets t
    SET max_attempts = GREATEST(1, LEAST(50, COALESCE(w.max_iterations, 10)))
    FROM workspaces w
    WHERE w.id = t.workspace_id
    """)

    execute("ALTER TABLE workspaces DROP CONSTRAINT IF EXISTS workspaces_max_iterations_check")

    alter table(:workspaces) do
      remove :max_iterations
    end
  end
end
