defmodule Algedonia.Repo.Migrations.CreateDagsAndLoops do
  use Ecto.Migration

  def change do
    create table(:dags, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false

      add :status, :text, null: false, default: "running"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:dags, [:ticket_id])

    execute(
      "ALTER TABLE dags ADD CONSTRAINT dags_status_check CHECK (status IN ('running', 'completed', 'failed'))",
      "ALTER TABLE dags DROP CONSTRAINT dags_status_check"
    )

    create table(:loops, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :dag_id, references(:dags, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "pending"
      add :role, :text, null: false, default: "task"
      add :manual_gate, :boolean, default: false

      add :assigned_daemon_id,
          references(:daemon_registrations, type: :binary_id, on_delete: :nilify_all)

      add :current_attempt, :integer, default: 0
      add :max_attempts, :integer, default: 10
      add :path_prefixes, {:array, :text}
      add :rubric, :text
      add :branch_name, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:loops, [:dag_id])
    create index(:loops, [:status])
    create index(:loops, [:assigned_daemon_id])

    execute(
      """
      ALTER TABLE loops ADD CONSTRAINT loops_status_check CHECK (
        status IN (
          'pending', 'ready', 'assigned', 'running_maker', 'running_checker',
          'passed', 'failed', 'escalated', 'needs_clarification',
          'pending_approval', 'skipped', 'resolved'
        )
      )
      """,
      "ALTER TABLE loops DROP CONSTRAINT loops_status_check"
    )

    execute(
      "ALTER TABLE loops ADD CONSTRAINT loops_role_check CHECK (role IN ('task', 'decompose', 'decompose_checker'))",
      "ALTER TABLE loops DROP CONSTRAINT loops_role_check"
    )

    create table(:loop_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :upstream_loop_id, references(:loops, type: :binary_id, on_delete: :delete_all),
        null: false

      add :downstream_loop_id, references(:loops, type: :binary_id, on_delete: :delete_all),
        null: false
    end

    create unique_index(:loop_dependencies, [:upstream_loop_id, :downstream_loop_id])
    create index(:loop_dependencies, [:downstream_loop_id])
  end
end
