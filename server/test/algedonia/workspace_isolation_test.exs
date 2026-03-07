defmodule Algedonia.WorkspaceIsolationTest do
  use Algedonia.DataCase, async: false

  alias Algedonia.Factory
  alias Algedonia.Repo

  setup do
    ensure_rls_test_role!()
    :ok
  end

  describe "tenant isolation with app.workspace_id" do
    test "workspace-scoped visibility across tenant tables" do
      workspace_a = Factory.insert_workspace!(%{name: "Workspace A", slug: "workspace-a"})
      workspace_b = Factory.insert_workspace!(%{name: "Workspace B", slug: "workspace-b"})

      ticket_a = Factory.insert_ticket!(%{workspace_id: workspace_a.id})
      ticket_b = Factory.insert_ticket!(%{workspace_id: workspace_b.id})

      _loop_a = Factory.insert_loop!(%{ticket_id: ticket_a.id, workspace_id: workspace_a.id})
      _loop_b = Factory.insert_loop!(%{ticket_id: ticket_b.id, workspace_id: workspace_b.id})

      insert_queue_entry!(workspace_a.id, ticket_a.id)
      insert_queue_entry!(workspace_b.id, ticket_b.id)
      insert_event!(workspace_a.id)
      insert_event!(workspace_b.id)

      run_as_rls_role(workspace_a.id, fn ->
        assert count_rows("tickets") == 1
        assert count_rows("loops") == 1
        assert count_rows("queue_entries") == 1
        assert count_rows("events") == 1
      end)

      run_as_rls_role(workspace_b.id, fn ->
        assert count_rows("tickets") == 1
        assert count_rows("loops") == 1
        assert count_rows("queue_entries") == 1
        assert count_rows("events") == 1
      end)
    end

    test "switching workspace context across transactions does not leak" do
      workspace_a = Factory.insert_workspace!(%{name: "Workspace C", slug: "workspace-c"})
      workspace_b = Factory.insert_workspace!(%{name: "Workspace D", slug: "workspace-d"})

      ticket_a = Factory.insert_ticket!(%{workspace_id: workspace_a.id, title: "A"})
      ticket_b = Factory.insert_ticket!(%{workspace_id: workspace_b.id, title: "B"})

      ids_a = run_as_rls_role(workspace_a.id, fn -> ticket_ids() end)
      ids_b = run_as_rls_role(workspace_b.id, fn -> ticket_ids() end)
      ids_a_again = run_as_rls_role(workspace_a.id, fn -> ticket_ids() end)

      assert ids_a == [ticket_a.id]
      assert ids_b == [ticket_b.id]
      assert ids_a_again == [ticket_a.id]
    end
  end

  defp run_as_rls_role(workspace_id, fun) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL ROLE algedonia_rls_test")
      Repo.set_local_workspace_id!(workspace_id)
      fun.()
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> flunk("rls transaction failed: #{inspect(reason)}")
    end
  end

  defp ticket_ids do
    %Postgrex.Result{rows: rows} = Repo.query!("SELECT id::text FROM tickets ORDER BY id")
    Enum.map(rows, fn [id] -> id end)
  end

  defp count_rows(table) do
    %Postgrex.Result{rows: [[count]]} = Repo.query!("SELECT COUNT(*)::int FROM #{table}")
    count
  end

  defp insert_queue_entry!(workspace_id, ticket_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      INSERT INTO queue_entries (id, workspace_id, ticket_id, status, position, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, 'queued', 0, $4, $4)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(workspace_id),
        Ecto.UUID.dump!(ticket_id),
        now
      ]
    )
  end

  defp insert_event!(workspace_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      INSERT INTO events (workspace_id, event_type, payload, inserted_at)
      VALUES ($1::uuid, 'test.event', '{}'::jsonb, $2)
      """,
      [Ecto.UUID.dump!(workspace_id), now]
    )
  end

  defp ensure_rls_test_role! do
    Repo.query!("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'algedonia_rls_test') THEN
        CREATE ROLE algedonia_rls_test;
      END IF;
    END
    $$;
    """)

    Repo.query!("GRANT USAGE ON SCHEMA public TO algedonia_rls_test")

    Repo.query!(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON tickets, loops, queue_entries, events TO algedonia_rls_test"
    )

    Repo.query!("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO algedonia_rls_test")
  end
end
