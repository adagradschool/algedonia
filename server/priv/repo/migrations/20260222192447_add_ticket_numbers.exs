defmodule Algedonia.Repo.Migrations.AddTicketNumbers do
  use Ecto.Migration

  def up do
    alter table(:tickets) do
      add :number, :bigint
    end

    execute "CREATE SEQUENCE IF NOT EXISTS tickets_number_seq"

    execute """
    UPDATE tickets
    SET number = subq.row_number
    FROM (
      SELECT id, ROW_NUMBER() OVER (ORDER BY inserted_at, id) AS row_number
      FROM tickets
    ) AS subq
    WHERE tickets.id = subq.id
    """

    execute "ALTER TABLE tickets ALTER COLUMN number SET DEFAULT nextval('tickets_number_seq')"

    execute "SELECT setval('tickets_number_seq', (SELECT GREATEST(COALESCE(MAX(number), 1), 1) FROM tickets), true)"

    alter table(:tickets) do
      modify :number, :bigint, null: false
    end

    create unique_index(:tickets, [:number])
  end

  def down do
    drop index(:tickets, [:number])

    alter table(:tickets) do
      remove :number
    end

    execute "DROP SEQUENCE IF EXISTS tickets_number_seq"
  end
end
