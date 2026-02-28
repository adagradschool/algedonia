defmodule Algedonia.OrchestratorTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.CheckerHandoff
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

  defp handle_attempt_complete(pid, loop_id, payload, daemon_name) do
    GenServer.call(pid, {:attempt_complete, loop_id, payload, daemon_name})
  end

  defp get_history(pid, loop_id) do
    GenServer.call(pid, {:get_loop_history, loop_id})
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
        assert payload["agent_type"] == "claude_code"
        assert payload["ticket"]["title"] == "My ticket"
        assert payload["ticket"]["description"] == "Do stuff"
        assert payload["ticket"]["type"] == "feature"
        assert payload["ticket"]["priority"] == 3
      end)
    end

    test "uses codex when ticket coding_agent is codex", %{orchestrator: pid} do
      ticket =
        insert_ticket!(%{
          status: :backlog,
          title: "Codex ticket",
          coding_agent: :codex
        })

      insert_daemon!(%{status: :online})

      assert :ok = start_work(pid, ticket.id)

      assert_receive {:push, _daemon_name, _loop_id, payload}
      assert payload["role"] == "decompose"
      assert payload["agent_type"] == "codex"
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
      assert checker_payload["agent_type"] == "claude_code"
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
      assert retry_payload["agent_type"] == "claude_code"
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

  describe "task loop checker handoff repair history" do
    test "does not add extra checker history entries for handoff repair", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})
      dag = insert_dag!(%{ticket_id: ticket.id})
      loop = insert_loop!(%{dag_id: dag.id, role: :task, status: :pending, max_attempts: 3})
      loop_id = loop.id
      daemon = insert_daemon!(%{status: :online})

      assert :ok = GenServer.call(pid, {:start_task_loop, loop_id, daemon.name, []})
      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop_id,
                 %{"session_id" => "maker-1", "exit_code" => 0},
                 daemon.name
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker"}}

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop_id,
                 %{
                   "session_id" => "checker-1",
                   "handoff_valid" => false,
                   "handoff_error" => "missing checker_result.json"
                 },
                 daemon.name
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "task" => repair_task}}
      assert repair_task =~ "REPAIR-ONLY MODE"

      history_after_repair = get_history(pid, loop_id)
      assert length(history_after_repair) == 2

      checker_entries_after_repair =
        Enum.filter(history_after_repair, &(&1.role == "checker" && &1.attempt == 1))

      assert length(checker_entries_after_repair) == 1
      assert hd(checker_entries_after_repair).status == "running"

      expected_feedback_path = CheckerHandoff.expected_paths(loop_id, 1).feedback

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop_id,
                 %{
                   "session_id" => "checker-2",
                   "handoff_valid" => true,
                   "verdict" => "fail",
                   "feedback" => "Needs more test coverage",
                   "feedback_path" => expected_feedback_path
                 },
                 daemon.name
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}

      final_history = get_history(pid, loop_id)

      checker_entries =
        Enum.filter(final_history, &(&1.role == "checker" && &1.attempt == 1))

      assert length(checker_entries) == 1

      checker_entry = hd(checker_entries)
      assert checker_entry.status == "completed"
      assert checker_entry.verdict == "fail"
      assert checker_entry.feedback == "Needs more test coverage"
    end
  end

  describe "start_task_loop agent selection" do
    test "defaults to ticket coding_agent when options do not provide agent_type", %{
      orchestrator: pid
    } do
      ticket = insert_ticket!(%{status: :in_progress, coding_agent: :claude_code})
      dag = insert_dag!(%{ticket_id: ticket.id})
      loop = insert_loop!(%{dag_id: dag.id, role: :task, status: :pending, max_attempts: 3})
      loop_id = loop.id
      daemon = insert_daemon!(%{status: :online})

      assert :ok = GenServer.call(pid, {:start_task_loop, loop.id, daemon.name, []})
      assert_receive {:push, _, ^loop_id, %{"role" => "maker", "agent_type" => "claude_code"}}
    end
  end

  describe "task context isolation" do
    test "maker task includes planning comment lookup command", %{orchestrator: pid} do
      ticket =
        insert_ticket!(%{
          status: :in_progress,
          title: "Context ticket",
          acceptance_criteria: "- must pass",
          rubric: "- quality"
        })

      {:ok, _comment} =
        Tickets.create_comment(%{
          ticket_id: ticket.id,
          author: "planner",
          body: "approved plan"
        })

      dag = insert_dag!(%{ticket_id: ticket.id})
      loop = insert_loop!(%{dag_id: dag.id, role: :task, status: :pending, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})
      loop_id = loop.id

      ticket_ref =
        if is_integer(ticket.number), do: Integer.to_string(ticket.number), else: ticket.id

      assert :ok = GenServer.call(pid, {:start_task_loop, loop.id, daemon.name, []})

      assert_receive {:push, _, ^loop_id, %{"role" => "maker", "task" => task}}
      assert task =~ "ag ticket comments #{ticket_ref} --json"
      assert task =~ "Fetch approved planning notes before implementation:"
    end

    test "checker task excludes planning notes and ticket comments", %{orchestrator: pid} do
      ticket =
        insert_ticket!(%{
          status: :in_progress,
          title: "Checker context ticket",
          acceptance_criteria: "- satisfy acceptance criteria",
          rubric: "- satisfy rubric"
        })

      {:ok, _comment} =
        Tickets.create_comment(%{
          ticket_id: ticket.id,
          author: "planner",
          body: "approved plan"
        })

      dag = insert_dag!(%{ticket_id: ticket.id})
      loop = insert_loop!(%{dag_id: dag.id, role: :task, status: :pending, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})
      loop_id = loop.id

      assert :ok = GenServer.call(pid, {:start_task_loop, loop.id, daemon.name, []})
      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 %{"session_id" => "maker-1", "exit_code" => 0},
                 daemon.name
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "task" => checker_task}}
      assert checker_task =~ "Acceptance criteria:\n- satisfy acceptance criteria"
      assert checker_task =~ "Rubric:\n- satisfy rubric"
      refute checker_task =~ "ag ticket comments"
      refute checker_task =~ "Ticket comments:"
      refute checker_task =~ "approved plan"
    end
  end

  # -- Task loop lifecycle tests --

  defp setup_task_loop(pid, opts \\ []) do
    ticket_attrs = Keyword.get(opts, :ticket, %{})
    loop_attrs = Keyword.get(opts, :loop, %{})

    ticket =
      insert_ticket!(Map.merge(%{status: :in_progress}, ticket_attrs))

    dag = insert_dag!(%{ticket_id: ticket.id})

    loop =
      insert_loop!(
        Map.merge(%{dag_id: dag.id, role: :task, status: :pending, max_attempts: 3}, loop_attrs)
      )

    daemon = insert_daemon!(%{status: :online})

    assert :ok = GenServer.call(pid, {:start_task_loop, loop.id, daemon.name, []})
    assert_receive {:push, _, _, %{"role" => "maker"}}

    %{ticket: ticket, dag: dag, loop: loop, daemon: daemon}
  end

  defp valid_checker_payload(loop_id, attempt, verdict, feedback) do
    expected_feedback_path = CheckerHandoff.expected_paths(loop_id, attempt).feedback

    %{
      "session_id" => "checker-#{attempt}",
      "exit_code" => 0,
      "handoff_valid" => true,
      "verdict" => verdict,
      "feedback" => feedback,
      "feedback_path" => expected_feedback_path
    }
  end

  describe "task loop: maker → checker transition" do
    test "maker completion starts checker run", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 %{"session_id" => "maker-1", "exit_code" => 0},
                 daemon.name
               )

      assert_receive {:push, _, loop_id, %{"role" => "checker", "attempt" => 1}}
      assert loop_id == loop.id

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :running_checker
    end

    test "maker completion records history", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}

      history = get_history(pid, loop.id)
      assert length(history) == 2

      [maker, checker] = history
      assert maker.role == "maker"
      assert maker.status == "completed"
      assert checker.role == "checker"
      assert checker.status == "running"
    end
  end

  describe "task loop: checker pass" do
    test "checker pass marks loop as passed", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 valid_checker_payload(loop.id, 1, "pass", "All checks pass"),
                 daemon.name
               )

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :passed
    end

    test "checker pass completes ticket when all loops pass", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon, ticket: ticket} = setup_task_loop(pid)

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}

      handle_attempt_complete(
        pid,
        loop.id,
        valid_checker_payload(loop.id, 1, "pass", "All good"),
        daemon.name
      )

      reloaded_ticket = Tickets.get_ticket!(ticket.id)
      assert reloaded_ticket.status == :completed
    end
  end

  describe "task loop: checker fail with retry" do
    test "checker fail retries maker with feedback", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 valid_checker_payload(loop.id, 1, "fail", "Missing error handling"),
                 daemon.name
               )

      assert_receive {:push, _, loop_id, %{"role" => "maker", "task" => task}}
      assert loop_id == loop.id
      assert task =~ "Missing error handling"

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :running_maker
      assert reloaded.current_attempt == 2
    end
  end

  describe "task loop: max attempts exhaustion" do
    test "loop fails after all attempts exhausted", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} =
        setup_task_loop(pid, loop: %{max_attempts: 2})

      # Attempt 1: maker → checker → fail
      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}

      handle_attempt_complete(
        pid,
        loop.id,
        valid_checker_payload(loop.id, 1, "fail", "Still broken"),
        daemon.name
      )

      assert_receive {:push, _, _, %{"role" => "maker"}}

      # Attempt 2: maker → checker → fail → exhausted
      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-2", "exit_code" => 0},
        daemon.name
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}

      handle_attempt_complete(
        pid,
        loop.id,
        valid_checker_payload(loop.id, 2, "fail", "Still broken again"),
        daemon.name
      )

      # No more maker push — loop is failed
      refute_receive {:push, _, _, %{"role" => "maker"}}, 100

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :failed
    end
  end

  describe "task loop: checker handoff repair cascade" do
    test "max handoff repairs exhausted falls back to retry", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)
      loop_id = loop.id

      # Maker completes
      handle_attempt_complete(
        pid,
        loop_id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name
      )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker"}}

      # Checker handoff invalid — repair 1
      handle_attempt_complete(
        pid,
        loop_id,
        %{"session_id" => "c1", "handoff_valid" => false, "handoff_error" => "missing json"},
        daemon.name
      )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "task" => t1}}
      assert t1 =~ "REPAIR-ONLY MODE"

      # Repair 1 also fails — repair 2
      handle_attempt_complete(
        pid,
        loop_id,
        %{"session_id" => "c2", "handoff_valid" => false, "handoff_error" => "still missing"},
        daemon.name
      )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "task" => t2}}
      assert t2 =~ "repair round 2"

      # Repair 2 also fails — exceeds max repairs, falls back to retry
      handle_attempt_complete(
        pid,
        loop_id,
        %{"session_id" => "c3", "handoff_valid" => false, "handoff_error" => "still missing"},
        daemon.name
      )

      # Should get a new maker attempt (retry)
      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}

      reloaded = Algedonia.Loops.get_loop!(loop_id)
      assert reloaded.status == :running_maker
      assert reloaded.current_attempt == 2
    end
  end

  describe "task loop: ensure_daemon fallback" do
    test "uses assigned daemon when daemon_name is nil", %{orchestrator: pid} do
      %{loop: loop} = setup_task_loop(pid)

      # Maker completes without explicit daemon_name
      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 %{"session_id" => "maker-1", "exit_code" => 0},
                 nil
               )

      assert_receive {:push, _, _, %{"role" => "checker"}}
    end
  end

  describe "step terminal ids" do
    test "returns current and latest step ids from loop history", %{orchestrator: pid} do
      loop_id = "loop-#{System.unique_integer([:positive])}"

      maker_step = %{id: "maker-step-1", role: "maker", attempt: 1, status: "completed"}
      checker_step = %{id: "checker-step-1", role: "checker", attempt: 1, status: "running"}

      :sys.replace_state(pid, fn state ->
        put_in(state, [:task_history, loop_id], [maker_step, checker_step])
      end)

      assert Orchestrator.current_step_terminal_id(loop_id, name: pid) == checker_step.id
      assert Orchestrator.latest_step_terminal_id(loop_id, name: pid) == checker_step.id
    end

    test "returns nil ids when loop has no history", %{orchestrator: pid} do
      loop_id = "empty-#{System.unique_integer([:positive])}"
      assert Orchestrator.current_step_terminal_id(loop_id, name: pid) == nil
      assert Orchestrator.latest_step_terminal_id(loop_id, name: pid) == nil
    end
  end
end
