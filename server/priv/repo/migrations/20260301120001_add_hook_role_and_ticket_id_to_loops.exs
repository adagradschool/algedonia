defmodule Algedonia.Repo.Migrations.AddHookRoleAndTicketIdToLoops do
  use Ecto.Migration

  def up do
    alter table(:loops) do
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all)
    end

    create index(:loops, [:ticket_id])

    execute """
    ALTER TABLE loops DROP CONSTRAINT IF EXISTS loops_role_check
    """

    execute """
    ALTER TABLE loops ADD CONSTRAINT loops_role_check
    CHECK (role IN ('task', 'hook'))
    """
  end

  def down do
    execute """
    ALTER TABLE loops DROP CONSTRAINT IF EXISTS loops_role_check
    """

    execute """
    ALTER TABLE loops ADD CONSTRAINT loops_role_check
    CHECK (role IN ('task'))
    """

    alter table(:loops) do
      remove :ticket_id
    end
  end
end
