defmodule Algedonia.Repo.Migrations.DropDagDecompositionSurface do
  use Ecto.Migration

  def up do
    # Clean-start migration: this permanently removes DAG/decomposition storage.
    # Existing DAG data is intentionally discarded per the single-loop-per-ticket redesign.
    drop_if_exists index(:loops, [:dag_id])

    execute """
    ALTER TABLE loops DROP CONSTRAINT IF EXISTS loops_role_check
    """

    execute """
    ALTER TABLE loops ADD CONSTRAINT loops_role_check
    CHECK (role IN ('task', 'hook'))
    """

    alter table(:loops) do
      remove :dag_id
    end

    drop_if_exists table(:loop_dependencies)
    drop_if_exists table(:dags)
  end

  def down do
    raise "irreversible migration: DAG/decomposition schema was intentionally removed for clean-start"
  end
end
