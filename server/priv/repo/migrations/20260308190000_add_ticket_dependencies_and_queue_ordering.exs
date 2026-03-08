defmodule Algedonia.Repo.Migrations.AddTicketDependenciesAndQueueOrdering do
  use Ecto.Migration

  def up do
    alter table(:tickets) do
      add :blocked_by, {:array, :binary_id}, null: false, default: []
    end

    execute("""
    DELETE FROM queue_entries q
    USING queue_entries d
    WHERE q.workspace_id = d.workspace_id
      AND q.ticket_id = d.ticket_id
      AND q.ticket_id IS NOT NULL
      AND q.id <> d.id
      AND q.inserted_at > d.inserted_at
    """)

    create unique_index(:queue_entries, [:workspace_id, :ticket_id],
             name: :idx_queue_entries_workspace_id_ticket_id_unique,
             where: "ticket_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists(
      index(:queue_entries, [:workspace_id, :ticket_id],
        name: :idx_queue_entries_workspace_id_ticket_id_unique
      )
    )

    alter table(:tickets) do
      remove :blocked_by
    end
  end
end
