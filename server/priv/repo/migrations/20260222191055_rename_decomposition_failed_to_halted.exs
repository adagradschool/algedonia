defmodule Algedonia.Repo.Migrations.RenameDecompositionFailedToHalted do
  use Ecto.Migration

  def up do
    execute "UPDATE tickets SET status = 'halted' WHERE status = 'decomposition_failed'"

    drop constraint(:tickets, :valid_status)

    create constraint(:tickets, :valid_status,
             check:
               "status IN ('backlog', 'decomposing', 'halted', 'in_progress', 'completed', 'archived')"
           )
  end

  def down do
    execute "UPDATE tickets SET status = 'decomposition_failed' WHERE status = 'halted'"

    drop constraint(:tickets, :valid_status)

    create constraint(:tickets, :valid_status,
             check:
               "status IN ('backlog', 'decomposing', 'decomposition_failed', 'in_progress', 'completed', 'archived')"
           )
  end
end
