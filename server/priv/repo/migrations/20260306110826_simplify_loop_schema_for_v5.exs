defmodule Algedonia.Repo.Migrations.SimplifyLoopSchemaForV5 do
  use Ecto.Migration

  def up do
    # -- Loop status simplification --
    execute "ALTER TABLE loops DROP CONSTRAINT IF EXISTS loops_status_check"

    # Map old statuses to new values in-place
    execute """
    UPDATE loops SET status = CASE status
      WHEN 'running_maker' THEN 'running'
      WHEN 'running_checker' THEN 'running'
      WHEN 'assigned' THEN 'pending'
      WHEN 'ready' THEN 'pending'
      WHEN 'needs_clarification' THEN 'failed'
      WHEN 'pending_approval' THEN 'failed'
      WHEN 'skipped' THEN 'failed'
      WHEN 'resolved' THEN 'passed'
      WHEN 'escalated' THEN 'failed'
      ELSE status
    END
    """

    execute """
    ALTER TABLE loops ADD CONSTRAINT loops_status_check
    CHECK (status IN ('pending', 'running', 'passed', 'failed'))
    """

    # -- New columns on loops --
    alter table(:loops) do
      add :checker_config, :map
      add :land_mode, :text
      add :pr_url, :text
    end

    execute """
    ALTER TABLE loops ADD CONSTRAINT loops_land_mode_check
    CHECK (land_mode IN ('auto_land', 'review_gate') OR land_mode IS NULL)
    """

    # -- New loop_steps table --
    create table(:loop_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :loop_id, references(:loops, type: :binary_id, on_delete: :delete_all), null: false

      add :role, :text, null: false
      add :attempt, :integer, null: false
      add :status, :text, null: false
      add :session_id, :text
      add :exit_code, :integer
      add :verdict, :text
      add :feedback, :text
      add :feedback_path, :text
      add :error, :text
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
    end

    create index(:loop_steps, [:loop_id])
    create index(:loop_steps, [:loop_id, :attempt, :role])

    execute """
    ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_role_check
    CHECK (role IN ('maker', 'checker'))
    """

    execute """
    ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_status_check
    CHECK (status IN ('running', 'completed', 'failed', 'handoff_invalid'))
    """
  end

  def down do
    raise "irreversible migration: loop status collapse and step table creation cannot be reversed"
  end
end
