defmodule Algedonia.Repo.Migrations.AddWorkspaceToTickets do
  use Ecto.Migration

  def up do
    alter table(:tickets) do
      add_if_not_exists :workspace_id,
                        references(:workspaces, type: :id, on_delete: :delete_all)
    end

    execute """
    INSERT INTO workspaces (name, slug, prefix, next_ticket_number, inserted_at, updated_at)
    VALUES ('Algedonia', 'algedonia', 'ALG', 1, now(), now())
    ON CONFLICT (slug) DO NOTHING
    """

    execute """
    UPDATE tickets
    SET workspace_id = (SELECT id FROM workspaces WHERE slug = 'algedonia' LIMIT 1)
    WHERE workspace_id IS NULL
    """

    execute """
    UPDATE workspaces
    SET next_ticket_number = (
      SELECT COALESCE(MAX(number), 0) + 1
      FROM tickets
      WHERE workspace_id = workspaces.id
    )
    WHERE slug = 'algedonia'
    """

    alter table(:tickets) do
      modify :workspace_id, :bigint, null: false
    end

    create_if_not_exists index(:tickets, [:workspace_id])
  end

  def down do
    drop_if_exists index(:tickets, [:workspace_id])

    alter table(:tickets) do
      remove_if_exists :workspace_id
    end
  end
end
