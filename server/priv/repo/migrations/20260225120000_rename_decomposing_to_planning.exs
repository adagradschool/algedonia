defmodule Algedonia.Repo.Migrations.RenameDecomposingToPlanning do
  use Ecto.Migration

  def up do
    execute "UPDATE tickets SET status = 'planning' WHERE status = 'decomposing'"

    drop constraint(:tickets, :valid_status)

    create constraint(:tickets, :valid_status,
             check:
               "status IN ('backlog', 'planning', 'halted', 'in_progress', 'completed', 'archived')"
           )
  end

  def down do
    execute "UPDATE tickets SET status = 'decomposing' WHERE status = 'planning'"

    drop constraint(:tickets, :valid_status)

    create constraint(:tickets, :valid_status,
             check:
               "status IN ('backlog', 'decomposing', 'halted', 'in_progress', 'completed', 'archived')"
           )
  end
end
