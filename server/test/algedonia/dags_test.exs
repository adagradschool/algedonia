defmodule Algedonia.DagsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Dags
  import Algedonia.Factory

  describe "create_dag_with_loops/2" do
    test "creates dag with loops and dependencies atomically" do
      ticket = insert_ticket!()

      dag_data = %{
        "loops" => [
          %{"temp_id" => "t1", "title" => "Setup environment", "role" => "task"},
          %{"temp_id" => "t2", "title" => "Implement feature", "role" => "task"},
          %{"temp_id" => "t3", "title" => "Write tests", "role" => "task"}
        ],
        "dependencies" => [
          %{"from" => "t1", "to" => "t2"},
          %{"from" => "t2", "to" => "t3"}
        ]
      }

      assert {:ok, dag} = Dags.create_dag_with_loops(%{ticket_id: ticket.id}, dag_data)
      assert dag.ticket_id == ticket.id
      assert dag.status == :running
      assert length(dag.loops) == 3
    end

    test "maps temporary IDs to real UUIDs in dependencies" do
      ticket = insert_ticket!()

      dag_data = %{
        "loops" => [
          %{"temp_id" => "a", "title" => "First"},
          %{"temp_id" => "b", "title" => "Second"}
        ],
        "dependencies" => [
          %{"from" => "a", "to" => "b"}
        ]
      }

      {:ok, dag} = Dags.create_dag_with_loops(%{ticket_id: ticket.id}, dag_data)
      deps = Dags.list_dependencies_for_dag(dag.id)

      assert length(deps) == 1
      dep = hd(deps)
      loop_ids = Enum.map(dag.loops, & &1.id)
      assert dep.upstream_loop_id in loop_ids
      assert dep.downstream_loop_id in loop_ids
      assert dep.upstream_loop_id != dep.downstream_loop_id
    end

    test "broadcasts :dag_created on PubSub" do
      ticket = insert_ticket!()
      Dags.subscribe(ticket.id)

      dag_data = %{
        "loops" => [%{"temp_id" => "x", "title" => "Only loop"}],
        "dependencies" => []
      }

      {:ok, dag} = Dags.create_dag_with_loops(%{ticket_id: ticket.id}, dag_data)
      assert_receive {:dag_created, ^dag}
    end

    test "enforces unique ticket_id constraint" do
      ticket = insert_ticket!()
      insert_dag!(%{ticket_id: ticket.id})

      dag_data = %{"loops" => [%{"temp_id" => "x", "title" => "Dup"}], "dependencies" => []}

      assert {:error, :dag, _changeset, _} =
               Dags.create_dag_with_loops(%{ticket_id: ticket.id}, dag_data)
    end
  end

  describe "get_dag_by_ticket/1" do
    test "returns dag with preloaded loops" do
      dag = insert_dag!()
      _loop = insert_loop!(%{dag_id: dag.id, title: "Test loop"})

      result = Dags.get_dag_by_ticket(dag.ticket_id)
      assert result.id == dag.id
      assert length(result.loops) == 1
    end

    test "returns nil when no dag exists" do
      assert is_nil(Dags.get_dag_by_ticket(Ecto.UUID.generate()))
    end
  end

  describe "update_dag_status/2" do
    test "updates status and broadcasts" do
      dag = insert_dag!()
      Dags.subscribe(dag.ticket_id)

      assert {:ok, updated} = Dags.update_dag_status(dag, :completed)
      assert updated.status == :completed
      assert_receive {:dag_updated, _}
    end
  end

  describe "list_loops_for_dag/1" do
    test "returns loops ordered by insertion time" do
      dag = insert_dag!()
      l1 = insert_loop!(%{dag_id: dag.id, title: "First"})
      _l2 = insert_loop!(%{dag_id: dag.id, title: "Second"})

      loops = Dags.list_loops_for_dag(dag.id)
      assert length(loops) == 2
      assert hd(loops).id == l1.id
    end
  end

  describe "list_dependencies_for_dag/1" do
    test "returns dependencies for a dag's loops" do
      dag = insert_dag!()
      l1 = insert_loop!(%{dag_id: dag.id, title: "Up"})
      l2 = insert_loop!(%{dag_id: dag.id, title: "Down"})
      insert_loop_dependency!(l1.id, l2.id)

      deps = Dags.list_dependencies_for_dag(dag.id)
      assert length(deps) == 1
      assert hd(deps).upstream_loop_id == l1.id
      assert hd(deps).downstream_loop_id == l2.id
    end
  end

  describe "first loop helpers" do
    test "first_loop_id/1 returns first task loop and ignores hooks" do
      ticket = insert_ticket!()
      dag = insert_dag!(%{ticket_id: ticket.id})
      _hook = insert_loop!(%{dag_id: dag.id, ticket_id: ticket.id, role: :hook, title: "Hook"})
      task = insert_loop!(%{dag_id: dag.id, ticket_id: ticket.id, role: :task, title: "Task"})

      assert Dags.first_loop_id(ticket.id) == task.id
    end

    test "first_loop_ids_for_tickets/1 maps tickets to task loops only" do
      ticket1 = insert_ticket!()
      dag1 = insert_dag!(%{ticket_id: ticket1.id})
      _hook1 = insert_loop!(%{dag_id: dag1.id, ticket_id: ticket1.id, role: :hook})
      task1 = insert_loop!(%{dag_id: dag1.id, ticket_id: ticket1.id, role: :task})

      ticket2 = insert_ticket!()
      dag2 = insert_dag!(%{ticket_id: ticket2.id})
      task2 = insert_loop!(%{dag_id: dag2.id, ticket_id: ticket2.id, role: :task})

      result = Dags.first_loop_ids_for_tickets([ticket1.id, ticket2.id])

      assert result[ticket1.id] == task1.id
      assert result[ticket2.id] == task2.id
    end

    test "first_inspect_loop_id/1 falls back to non-hook loops when no task loop exists" do
      ticket = insert_ticket!()
      dag = insert_dag!(%{ticket_id: ticket.id})
      _hook = insert_loop!(%{dag_id: dag.id, ticket_id: ticket.id, role: :hook})
      legacy = insert_loop!(%{dag_id: dag.id, ticket_id: ticket.id, role: :decompose})

      assert Dags.first_inspect_loop_id(ticket.id) == legacy.id
    end

    test "active_loop_info_for_tickets/1 returns stage and attempt for active loops" do
      ticket = insert_ticket!()
      dag = insert_dag!(%{ticket_id: ticket.id})

      insert_loop!(%{
        dag_id: dag.id,
        ticket_id: ticket.id,
        role: :task,
        status: :running_checker,
        current_attempt: 2
      })

      result = Dags.active_loop_info_for_tickets([ticket.id])
      info = result[ticket.id]

      assert info.stage == "checker"
      assert info.attempt == 2
    end

    test "active_loop_info_for_tickets/1 falls back with terminal loop stage and attempt" do
      ticket = insert_ticket!()
      dag = insert_dag!(%{ticket_id: ticket.id})

      loop =
        insert_loop!(%{
          dag_id: dag.id,
          ticket_id: ticket.id,
          role: :task,
          status: :passed,
          current_attempt: 3
        })

      result = Dags.active_loop_info_for_tickets([ticket.id])
      info = result[ticket.id]

      assert info.loop_id == loop.id
      assert info.stage == "completed"
      assert info.attempt == 3
    end

    test "first_inspect_loop_ids_for_tickets/1 prefers task loops then falls back" do
      ticket1 = insert_ticket!()
      dag1 = insert_dag!(%{ticket_id: ticket1.id})
      task1 = insert_loop!(%{dag_id: dag1.id, ticket_id: ticket1.id, role: :task})
      _legacy1 = insert_loop!(%{dag_id: dag1.id, ticket_id: ticket1.id, role: :decompose})

      ticket2 = insert_ticket!()
      dag2 = insert_dag!(%{ticket_id: ticket2.id})
      _hook2 = insert_loop!(%{dag_id: dag2.id, ticket_id: ticket2.id, role: :hook})
      legacy2 = insert_loop!(%{dag_id: dag2.id, ticket_id: ticket2.id, role: :decompose_checker})

      result = Dags.first_inspect_loop_ids_for_tickets([ticket1.id, ticket2.id])

      assert result[ticket1.id] == task1.id
      assert result[ticket2.id] == legacy2.id
    end
  end
end
