defmodule Algedonia.Repo.Migrations.EnforceWorkspaceIsolationOnTenantTables do
  use Ecto.Migration

  def up do
    alter table(:loops) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
    end

    execute("""
    UPDATE loops AS l
    SET workspace_id = t.workspace_id
    FROM tickets AS t
    WHERE l.ticket_id = t.id AND l.workspace_id IS NULL
    """)

    execute("""
    ALTER TABLE loops
    ALTER COLUMN workspace_id SET NOT NULL
    """)

    drop_if_exists(index(:tickets, [:status], name: :idx_tickets_status))
    drop_if_exists(index(:tickets, [:priority], name: :idx_tickets_priority))
    drop_if_exists(index(:tickets, [:assignee], name: :idx_tickets_assignee))

    create index(:tickets, [:workspace_id, :status], name: :idx_tickets_workspace_id_status)
    create index(:tickets, [:workspace_id, :priority], name: :idx_tickets_workspace_id_priority)

    create index(:tickets, [:workspace_id, :assignee],
             name: :idx_tickets_workspace_id_assignee,
             where: "assignee IS NOT NULL"
           )

    drop_if_exists(index(:loops, [:status], name: :idx_loops_status))
    drop_if_exists(index(:loops, [:ticket_id], name: :idx_loops_ticket_id))

    create index(:loops, [:workspace_id, :status], name: :idx_loops_workspace_id_status)
    create index(:loops, [:workspace_id, :ticket_id], name: :idx_loops_workspace_id_ticket_id)

    create index(:loops, [:workspace_id, :assigned_daemon_id, :status],
             name: :idx_loops_workspace_id_assigned_daemon_id_status
           )

    execute("""
    CREATE TABLE IF NOT EXISTS queue_entries (
      id uuid PRIMARY KEY,
      workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      ticket_id uuid REFERENCES tickets(id) ON DELETE CASCADE,
      status text NOT NULL DEFAULT 'queued',
      position integer NOT NULL DEFAULT 0,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS events (
      id bigserial PRIMARY KEY,
      workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      event_type text NOT NULL,
      payload jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamp(6) without time zone NOT NULL
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_queue_entries_workspace_id_status
    ON queue_entries (workspace_id, status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_queue_entries_workspace_id_position
    ON queue_entries (workspace_id, position)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_queue_entries_workspace_id_ticket_id
    ON queue_entries (workspace_id, ticket_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_events_workspace_id_inserted_at
    ON events (workspace_id, inserted_at)
    """)

    execute("ALTER TABLE tickets ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE tickets FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE loops ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE loops FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE queue_entries ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE queue_entries FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE events ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE events FORCE ROW LEVEL SECURITY")

    execute("DROP POLICY IF EXISTS tickets_workspace_isolation ON tickets")
    execute("DROP POLICY IF EXISTS loops_workspace_isolation ON loops")
    execute("DROP POLICY IF EXISTS queue_entries_workspace_isolation ON queue_entries")
    execute("DROP POLICY IF EXISTS events_workspace_isolation ON events")

    execute("""
    CREATE POLICY tickets_workspace_isolation ON tickets
    USING (workspace_id = current_setting('app.workspace_id')::uuid)
    WITH CHECK (workspace_id = current_setting('app.workspace_id')::uuid)
    """)

    execute("""
    CREATE POLICY loops_workspace_isolation ON loops
    USING (workspace_id = current_setting('app.workspace_id')::uuid)
    WITH CHECK (workspace_id = current_setting('app.workspace_id')::uuid)
    """)

    execute("""
    CREATE POLICY queue_entries_workspace_isolation ON queue_entries
    USING (workspace_id = current_setting('app.workspace_id')::uuid)
    WITH CHECK (workspace_id = current_setting('app.workspace_id')::uuid)
    """)

    execute("""
    CREATE POLICY events_workspace_isolation ON events
    USING (workspace_id = current_setting('app.workspace_id')::uuid)
    WITH CHECK (workspace_id = current_setting('app.workspace_id')::uuid)
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS tickets_workspace_isolation ON tickets")
    execute("DROP POLICY IF EXISTS loops_workspace_isolation ON loops")
    execute("DROP POLICY IF EXISTS queue_entries_workspace_isolation ON queue_entries")
    execute("DROP POLICY IF EXISTS events_workspace_isolation ON events")

    execute("ALTER TABLE tickets NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE loops NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE queue_entries NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE events NO FORCE ROW LEVEL SECURITY")

    execute("ALTER TABLE tickets DISABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE loops DISABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE queue_entries DISABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE events DISABLE ROW LEVEL SECURITY")

    drop_if_exists(
      index(:events, [:workspace_id, :inserted_at], name: :idx_events_workspace_id_inserted_at)
    )

    drop_if_exists(
      index(:queue_entries, [:workspace_id, :ticket_id],
        name: :idx_queue_entries_workspace_id_ticket_id
      )
    )

    drop_if_exists(
      index(:queue_entries, [:workspace_id, :position],
        name: :idx_queue_entries_workspace_id_position
      )
    )

    drop_if_exists(
      index(:queue_entries, [:workspace_id, :status],
        name: :idx_queue_entries_workspace_id_status
      )
    )

    execute("DROP TABLE IF EXISTS events")
    execute("DROP TABLE IF EXISTS queue_entries")

    drop_if_exists(
      index(:loops, [:workspace_id, :assigned_daemon_id, :status],
        name: :idx_loops_workspace_id_assigned_daemon_id_status
      )
    )

    drop_if_exists(
      index(:loops, [:workspace_id, :ticket_id], name: :idx_loops_workspace_id_ticket_id)
    )

    drop_if_exists(index(:loops, [:workspace_id, :status], name: :idx_loops_workspace_id_status))

    create index(:loops, [:status], name: :idx_loops_status)
    create index(:loops, [:ticket_id], name: :idx_loops_ticket_id)

    drop_if_exists(
      index(:tickets, [:workspace_id, :assignee], name: :idx_tickets_workspace_id_assignee)
    )

    drop_if_exists(
      index(:tickets, [:workspace_id, :priority], name: :idx_tickets_workspace_id_priority)
    )

    drop_if_exists(
      index(:tickets, [:workspace_id, :status], name: :idx_tickets_workspace_id_status)
    )

    create index(:tickets, [:status], name: :idx_tickets_status)
    create index(:tickets, [:priority], name: :idx_tickets_priority)
    create index(:tickets, [:assignee], name: :idx_tickets_assignee)

    alter table(:loops) do
      remove :workspace_id
    end
  end
end
