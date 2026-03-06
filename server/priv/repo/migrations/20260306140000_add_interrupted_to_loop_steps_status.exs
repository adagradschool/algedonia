defmodule Algedonia.Repo.Migrations.AddInterruptedToLoopStepsStatus do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE loop_steps DROP CONSTRAINT loop_steps_status_check"

    execute """
    ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_status_check
    CHECK (status IN ('running', 'completed', 'failed', 'handoff_invalid', 'interrupted'))
    """
  end

  def down do
    execute "ALTER TABLE loop_steps DROP CONSTRAINT loop_steps_status_check"

    execute """
    UPDATE loop_steps SET status = 'failed' WHERE status = 'interrupted'
    """

    execute """
    ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_status_check
    CHECK (status IN ('running', 'completed', 'failed', 'handoff_invalid'))
    """
  end
end
