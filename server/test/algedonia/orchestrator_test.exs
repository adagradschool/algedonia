defmodule Algedonia.OrchestratorTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.{Dags, Orchestrator, Repo, Tickets}
  alias Ecto.Adapters.SQL.Sandbox
  import Algedonia.Factory

  setup do
    test_pid = self()

    push_fn = fn daemon_name, loop_id, opts ->
      send(test_pid, {:push, daemon_name, loop_id, opts})
      :ok
    end

    name = :"orchestrator_#{System.unique_integer([:positive])}"

    {:ok, pid} = Orchestrator.start_link(push_fn: push_fn, name: name)

    # Allow the GenServer to use this test's DB connection
    Sandbox.allow(Repo, self(), pid)

    {:ok, orchestrator: pid}
  end

  defp start_work(pid, ticket_id) do
    GenServer.call(pid, {:start_work, ticket_id})
  end

  defp handle_result(pid, loop_id, payload) do
    GenServer.call(pid, {:loop_result, loop_id, payload})
  end

  defp handle_error(pid, loop_id, error) do
    GenServer.call(pid, {:loop_error, loop_id, error})
  end

  describe "start_work/1" do
    test "creates decompose dag and pushes to daemon with ticket context", %{orchestrator: pid} do
      insert_ticket!(%{status: :backlog, title: "My ticket", description: "Do stuff"})
      |> then(fn ticket ->
        insert_daemon!(%{status: :online})

        assert :ok = start_work(pid, ticket.id)

        ticket = Tickets.get_ticket!(ticket.id)
        assert ticket.status == :planning

        dag = Dags.get_dag_by_ticket(ticket.id)
        assert dag
        assert dag.status == :running

        assert_receive {:push, _daemon_name, _loop_id, payload}
        assert payload["role"] == "decompose"
        assert payload["ticket"]["title"] == "My ticket"
        assert payload["ticket"]["description"] == "Do stuff"
        assert payload["ticket"]["type"] == "feature"
        assert payload["ticket"]["priority"] == 3
      end)
    end

    test "rejects ticket not in backlog", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})
      insert_daemon!(%{status: :online})

      assert {:error, :invalid_status} = start_work(pid, ticket.id)
    end

    test "fails when no daemon is online", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :backlog})

      assert {:error, :no_online_daemon} = start_work(pid, ticket.id)
    end
  end

  describe "handle_loop_result - decompose pass" do
    test "stores proposed dag and sends checker with ticket context", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :backlog, title: "Checker ticket"})
      insert_daemon!(%{status: :online})

      :ok = start_work(pid, ticket.id)
      assert_receive {:push, _, decompose_loop_id, %{"role" => "decompose"}}

      dag_data = %{
        "loops" => [
          %{"temp_id" => "t1", "title" => "Task 1"},
          %{"temp_id" => "t2", "title" => "Task 2"}
        ],
        "dependencies" => [%{"from" => "t1", "to" => "t2"}]
      }

      :ok = handle_result(pid, decompose_loop_id, %{"verdict" => "pass", "dag" => dag_data})

      assert_receive {:push, _, _checker_loop_id, checker_payload}
      assert checker_payload["role"] == "decompose_checker"
      assert checker_payload["ticket"]["title"] == "Checker ticket"
    end
  end

  describe "handle_loop_result - checker pass" do
    test "creates real DAG and transitions ticket to in_progress", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :backlog})
      insert_daemon!(%{status: :online})

      :ok = start_work(pid, ticket.id)
      assert_receive {:push, _, decompose_loop_id, %{"role" => "decompose"}}

      dag_data = %{
        "loops" => [
          %{"temp_id" => "t1", "title" => "Task 1"},
          %{"temp_id" => "t2", "title" => "Task 2"}
        ],
        "dependencies" => [%{"from" => "t1", "to" => "t2"}]
      }

      :ok = handle_result(pid, decompose_loop_id, %{"verdict" => "pass", "dag" => dag_data})
      assert_receive {:push, _, checker_loop_id, %{"role" => "decompose_checker"}}

      :ok = handle_result(pid, checker_loop_id, %{"verdict" => "pass"})

      ticket = Tickets.get_ticket!(ticket.id)
      assert ticket.status == :in_progress

      dag = Dags.get_dag_by_ticket(ticket.id)
      assert dag
      assert length(dag.loops) == 2
    end
  end

  describe "handle_loop_result - checker fail with retries" do
    test "retries decompose with feedback and ticket context", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :backlog, title: "Retry ticket"})
      insert_daemon!(%{status: :online})

      :ok = start_work(pid, ticket.id)
      assert_receive {:push, _, decompose_loop_id, %{"role" => "decompose"}}

      dag_data = %{
        "loops" => [%{"temp_id" => "t1", "title" => "Bad task"}],
        "dependencies" => []
      }

      :ok = handle_result(pid, decompose_loop_id, %{"verdict" => "pass", "dag" => dag_data})
      assert_receive {:push, _, checker_loop_id, %{"role" => "decompose_checker"}}

      :ok =
        handle_result(pid, checker_loop_id, %{
          "verdict" => "fail",
          "feedback" => "Tasks are too coarse"
        })

      assert_receive {:push, _, _new_loop_id, retry_payload}
      assert retry_payload["role"] == "decompose"
      assert retry_payload["feedback"] == "Tasks are too coarse"
      assert retry_payload["ticket"]["title"] == "Retry ticket"
    end
  end

  describe "handle_loop_result - checker fail max attempts" do
    test "marks ticket as halted after max retries", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :backlog})
      insert_daemon!(%{status: :online})

      :ok = start_work(pid, ticket.id)

      for _i <- 1..3 do
        assert_receive {:push, _, loop_id, %{"role" => "decompose"}}

        dag_data = %{
          "loops" => [%{"temp_id" => "t1", "title" => "Bad"}],
          "dependencies" => []
        }

        :ok = handle_result(pid, loop_id, %{"verdict" => "pass", "dag" => dag_data})
        assert_receive {:push, _, checker_id, %{"role" => "decompose_checker"}}

        :ok = handle_result(pid, checker_id, %{"verdict" => "fail", "feedback" => "Bad"})
      end

      ticket = Tickets.get_ticket!(ticket.id)
      assert ticket.status == :halted
    end
  end

  describe "handle_loop_error/2" do
    test "retries on error when attempts remain", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :backlog})
      insert_daemon!(%{status: :online})

      :ok = start_work(pid, ticket.id)
      assert_receive {:push, _, loop_id, %{"role" => "decompose"}}

      :ok = handle_error(pid, loop_id, %{"message" => "process crashed"})

      assert_receive {:push, _, _new_loop_id, retry_payload}
      assert retry_payload["role"] == "decompose"
      assert is_map(retry_payload["ticket"])
    end
  end
end
