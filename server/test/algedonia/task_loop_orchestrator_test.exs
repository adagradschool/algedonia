defmodule Algedonia.TaskLoopOrchestratorTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.CheckerHandoff
  alias Algedonia.{Loops, Repo, TaskLoopOrchestrator, TenantScope, Tickets}
  alias Ecto.Adapters.SQL.Sandbox
  import Algedonia.Factory

  setup do
    test_pid = self()

    push_fn = fn daemon_name, loop_id, opts ->
      send(test_pid, {:push, daemon_name, loop_id, opts})
      :ok
    end

    name = :"task_loop_orchestrator_#{System.unique_integer([:positive])}"

    {:ok, pid} = TaskLoopOrchestrator.start_link(push_fn: push_fn, name: name)

    # Allow the GenServer to use this test's DB connection
    Sandbox.allow(Repo, self(), pid)

    workspace = default_workspace!()
    previous_scope = put_workspace_scope(workspace)
    on_exit(fn -> restore_workspace_scope(previous_scope) end)

    {:ok, orchestrator: pid, workspace: workspace}
  end

  defp handle_attempt_complete(pid, loop_id, payload, daemon_name, workspace_id) do
    GenServer.call(pid, {:attempt_complete, loop_id, payload, daemon_name, workspace_id})
  end

  defp handle_attempt_complete(pid, loop_id, payload, daemon_name) do
    handle_attempt_complete(pid, loop_id, payload, daemon_name, TenantScope.get_workspace())
  end

  defp handle_attempt_error(pid, loop_id, payload, daemon_name, workspace_id) do
    GenServer.call(pid, {:attempt_error, loop_id, payload, daemon_name, workspace_id})
  end

  defp get_history(pid, loop_id, workspace_id) do
    GenServer.call(pid, {:get_loop_history, loop_id, workspace_id})
  end

  defp get_history(pid, loop_id) do
    get_history(pid, loop_id, TenantScope.get_workspace())
  end

  describe "task loop checker handoff repair history" do
    test "does not add extra checker history entries for handoff repair", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :pending,
          max_attempts: 3
        })

      loop_id = loop.id
      daemon = insert_daemon!(%{status: :online})

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop_id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop_id,
                 %{"session_id" => "maker-1", "exit_code" => 0},
                 daemon.name,
                 loop.workspace_id
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
                 daemon.name,
                 loop.workspace_id
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "task" => repair_task}}
      assert repair_task =~ "REPAIR-ONLY MODE"

      history_after_repair = get_history(pid, loop_id)
      assert length(history_after_repair) == 2

      checker_entries_after_repair =
        Enum.filter(history_after_repair, &(&1.role == "checker" && &1.attempt == 1))

      assert length(checker_entries_after_repair) == 1
      assert hd(checker_entries_after_repair).status == "running"

      expected_feedback_path =
        CheckerHandoff.expected_paths(loop_id, 1, workspace_slug_for_loop(loop_id)).feedback

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
                 daemon.name,
                 loop.workspace_id
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

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :pending,
          max_attempts: 3
        })

      loop_id = loop.id
      daemon = insert_daemon!(%{status: :online})

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker", "agent_type" => "claude_code"}}
    end
  end

  describe "start_task_loop includes ticket_id" do
    test "push payload contains ticket_id", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :pending,
          max_attempts: 3
        })

      loop_id = loop.id
      daemon = insert_daemon!(%{status: :online})

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      ticket_id = ticket.id
      assert_receive {:push, _, ^loop_id, %{"role" => "maker", "ticket_id" => ^ticket_id}}
    end
  end

  describe "task context isolation" do
    test "maker task includes ticket comments", %{orchestrator: pid} do
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

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :pending,
          max_attempts: 3
        })

      daemon = insert_daemon!(%{status: :online})
      loop_id = loop.id

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker", "task" => task}}
      assert task =~ "Ticket comments:"
      assert task =~ "[planner] approved plan"
      refute task =~ "ag ticket comments"
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

      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})
      loop_id = loop.id

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 %{"session_id" => "maker-1", "exit_code" => 0},
                 daemon.name,
                 loop.workspace_id
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "task" => checker_task}}
      assert checker_task =~ "Acceptance criteria:\n- satisfy acceptance criteria"
      assert checker_task =~ "Rubric:\n- satisfy rubric"
      refute checker_task =~ "ag ticket comments"
      refute checker_task =~ "Ticket comments:"
      refute checker_task =~ "approved plan"
    end
  end

  describe "inline review inclusion in maker prompt" do
    test "pending inline reviews appear in maker task on retry", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress, title: "Review ticket"})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})
      loop_id = loop.id

      # Create a pending inline review
      {:ok, _review} =
        Algedonia.InlineReviews.create(%{
          loop_id: loop.id,
          author: "ada",
          file_path: "lib/orchestrator.ex",
          line_number: 42,
          diff_hunk: "-    old_code()\n+    new_code()",
          body: "Add error handling here."
        })

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker", "task" => task}}

      assert task =~ "Inline review comments:"
      assert task =~ "--- lib/orchestrator.ex:42"
      assert task =~ "Add error handling here."
      assert task =~ "ada"
    end

    test "resolved inline reviews are excluded from maker task", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress, title: "Resolved review ticket"})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})
      loop_id = loop.id

      {:ok, review} =
        Algedonia.InlineReviews.create(%{
          loop_id: loop.id,
          author: "ada",
          file_path: "lib/app.ex",
          line_number: 10,
          diff_hunk: "+    code()",
          body: "Already resolved."
        })

      {:ok, _} = Algedonia.InlineReviews.update_status(review, :resolved)

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker", "task" => task}}

      refute task =~ "Inline review comments:"
      refute task =~ "Already resolved."
    end
  end

  # -- Task loop lifecycle tests --

  defp setup_task_loop(pid, opts \\ []) do
    ticket_attrs = Keyword.get(opts, :ticket, %{})
    loop_attrs = Keyword.get(opts, :loop, %{})

    ticket =
      insert_ticket!(Map.merge(%{status: :in_progress}, ticket_attrs))

    loop =
      insert_loop!(
        Map.merge(
          %{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3},
          loop_attrs
        )
      )

    daemon = insert_daemon!(%{status: :online})

    assert :ok =
             GenServer.call(
               pid,
               {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
             )

    assert_receive {:push, _, _, %{"role" => "maker"}}

    %{ticket: ticket, loop: loop, daemon: daemon}
  end

  defp valid_checker_payload(loop_id, attempt, verdict, feedback, extra \\ %{}) do
    expected_feedback_path =
      CheckerHandoff.expected_paths(loop_id, attempt, workspace_slug_for_loop(loop_id)).feedback

    Map.merge(
      %{
        "session_id" => "checker-#{attempt}",
        "exit_code" => 0,
        "handoff_valid" => true,
        "verdict" => verdict,
        "feedback" => feedback,
        "feedback_path" => expected_feedback_path
      },
      extra
    )
  end

  defp checker_pipeline_config do
    %{"steps" => [%{"skill" => "pull", "params" => %{"mode" => "rebase"}}]}
  end

  defp workspace_slug_for_loop(loop_id) do
    loop_id
    |> Loops.get_loop!()
    |> Loops.preload_with_workspace()
    |> then(fn loop -> loop.ticket.workspace.slug end)
  end

  describe "task loop: maker → checker transition" do
    test "maker completion starts checker run", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 %{"session_id" => "maker-1", "exit_code" => 0},
                 daemon.name,
                 loop.workspace_id
               )

      assert_receive {:push, _, loop_id, %{"role" => "checker", "attempt" => 1}}
      assert loop_id == loop.id

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :running
    end

    test "maker completion records history", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}, 1_000

      history = get_history(pid, loop.id)
      assert length(history) == 2

      [maker, checker] = history
      assert maker.role == "maker"
      assert maker.status == "completed"
      assert checker.role == "checker"
      assert checker.status == "running"
    end
  end

  describe "task loop: maker → checker transition regression" do
    test "existing running loop without step history transitions on first attempt", %{
      orchestrator: pid
    } do
      ticket = insert_ticket!(%{status: :in_progress})
      daemon = insert_daemon!(%{status: :online})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :running,
          current_attempt: 1,
          max_attempts: 3,
          assigned_daemon_id: daemon.id
        })

      loop_id = loop.id

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop_id,
                 %{"role" => "maker", "session_id" => "maker-existing-1", "exit_code" => 0},
                 daemon.name,
                 loop.workspace_id
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "attempt" => 1}}

      history = get_history(pid, loop_id)
      assert length(history) == 1

      [checker] = history
      assert checker.role == "checker"
      assert checker.attempt == 1
      assert checker.status == "running"
    end

    test "existing running loop without step history transitions on retry attempt", %{
      orchestrator: pid
    } do
      ticket = insert_ticket!(%{status: :in_progress})
      daemon = insert_daemon!(%{status: :online})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :running,
          current_attempt: 2,
          max_attempts: 3,
          assigned_daemon_id: daemon.id
        })

      loop_id = loop.id

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop_id,
                 %{"role" => "maker", "session_id" => "maker-existing-2", "exit_code" => 0},
                 daemon.name,
                 loop.workspace_id
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "attempt" => 2}}

      history = get_history(pid, loop_id)
      assert length(history) == 1

      [checker] = history
      assert checker.role == "checker"
      assert checker.attempt == 2
      assert checker.status == "running"
    end

    test "marks loop failed with transition error when checker dispatch cannot start", %{
      orchestrator: pid
    } do
      ticket = insert_ticket!(%{status: :in_progress})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :running,
          current_attempt: 1,
          max_attempts: 3
        })

      loop_id = loop.id

      {:ok, _maker_step} =
        Loops.create_step(%{
          loop_id: loop_id,
          role: "maker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop_id,
                 %{"role" => "maker", "session_id" => "maker-1", "exit_code" => 0},
                 "missing-daemon",
                 loop.workspace_id
               )

      refute_receive {:push, _, ^loop_id, %{"role" => "checker"}}, 100

      reloaded = Algedonia.Loops.get_loop!(loop_id)
      assert reloaded.status == :failed

      history = get_history(pid, loop_id)
      assert length(history) == 2

      [maker, checker] = history
      assert maker.role == "maker"
      assert maker.status == "completed"
      assert checker.role == "checker"
      assert checker.status == "failed"
      assert checker.error =~ "Checker transition error"
    end
  end

  describe "task loop: maker error recovery" do
    test "maker error retries with next maker attempt", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)
      loop_id = loop.id

      assert :ok =
               handle_attempt_error(
                 pid,
                 loop.id,
                 %{
                   "session_id" => "maker-1",
                   "exit_code" => 2,
                   "message" => "agent exited with code 2"
                 },
                 daemon.name,
                 loop.workspace_id
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}
      assert loop_id == loop.id

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :running
      assert reloaded.current_attempt == 2
    end
  end

  describe "task loop: checker pass" do
    test "checker pass marks loop as passed", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}, 1_000

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 valid_checker_payload(loop.id, 1, "pass", "All checks pass"),
                 daemon.name,
                 loop.workspace_id
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
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}, 1_000

      handle_attempt_complete(
        pid,
        loop.id,
        valid_checker_payload(loop.id, 1, "pass", "All good"),
        daemon.name,
        loop.workspace_id
      )

      reloaded_ticket = Tickets.get_ticket!(ticket.id)
      assert reloaded_ticket.status == :completed
    end

    test "checker pass completes ticket even when hook loop is pending", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon, ticket: ticket} = setup_task_loop(pid)

      _hook_loop = insert_loop!(%{ticket_id: ticket.id, role: :hook, status: :pending})

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}, 1_000

      handle_attempt_complete(
        pid,
        loop.id,
        valid_checker_payload(loop.id, 1, "pass", "All good"),
        daemon.name,
        loop.workspace_id
      )

      reloaded_ticket = Tickets.get_ticket!(ticket.id)
      assert reloaded_ticket.status == :completed
    end
  end

  describe "task loop: ordered checker pipeline receipts" do
    test "persists ordered checker step receipts with required metadata", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} =
        setup_task_loop(pid, loop: %{checker_config: checker_pipeline_config()})

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}, 1_000

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 valid_checker_payload(loop.id, 1, "pass", "all checks passed", %{
                   "checker_step_receipts" => [
                     %{
                       "step_id" => "base-just-lint-and-test",
                       "skill" => "command",
                       "order_index" => 0,
                       "required" => true,
                       "verdict" => "pass",
                       "summary" => "Base pipeline passed."
                     },
                     %{
                       "step_id" => "ticket-orchestrator-tests",
                       "skill" => "command",
                       "order_index" => 1,
                       "required" => true,
                       "verdict" => "pass",
                       "summary" => "Ticket checker step passed."
                     }
                   ]
                 }),
                 daemon.name,
                 loop.workspace_id
               )

      checker_receipts =
        get_history(pid, loop.id)
        |> Enum.filter(&(&1.role == "checker" && &1.attempt == 1))
        |> Enum.sort_by(& &1.order_index)

      assert length(checker_receipts) == 2
      [base, ticket] = checker_receipts

      assert base.step_id == "base-just-lint-and-test"
      assert base.skill == "command"
      assert base.order_index == 0
      assert base.required == true
      assert base.verdict == "pass"
      assert base.summary == "Base pipeline passed."
      assert base.attempt == 1

      assert ticket.step_id == "checker-step-1"
      assert ticket.skill == "pull"
      assert ticket.order_index == 1
      assert ticket.required == true
      assert ticket.verdict == "pass"
      assert ticket.summary == "Ticket checker step passed."
      assert ticket.attempt == 1
    end

    test "required-step failure blocks pass and emits structured retry feedback", %{
      orchestrator: pid
    } do
      %{loop: loop, daemon: daemon} =
        setup_task_loop(pid, loop: %{checker_config: checker_pipeline_config(), max_attempts: 3})

      loop_id = loop.id

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}, 1_000

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 valid_checker_payload(loop.id, 1, "fail", "ticket checker failed", %{
                   "checker_step_receipts" => [
                     %{
                       "step_id" => "base-just-lint-and-test",
                       "skill" => "command",
                       "order_index" => 0,
                       "required" => true,
                       "verdict" => "pass",
                       "summary" => "Base pipeline passed."
                     },
                     %{
                       "step_id" => "checker-step-1",
                       "skill" => "pull",
                       "order_index" => 1,
                       "required" => true,
                       "verdict" => "fail",
                       "summary" => "Task loop orchestrator tests failed."
                     }
                   ]
                 }),
                 daemon.name,
                 loop.workspace_id
               )

      assert_receive {:push, _, ^loop_id, %{"role" => "maker", "task" => task} = retry_payload}
      assert task =~ "step_id: checker-step-1"
      assert task =~ "summary: Task loop orchestrator tests failed."

      assert retry_payload["checker_failure"] == %{
               "step_id" => "checker-step-1",
               "skill" => "pull",
               "order_index" => 1,
               "required" => true,
               "verdict" => "fail",
               "summary" => "Task loop orchestrator tests failed.",
               "attempt" => 1
             }

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :running
      refute reloaded.status == :passed
    end

    test "checker exhaustion halts ticket and retains last failed receipt", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon, ticket: ticket} =
        setup_task_loop(pid, loop: %{checker_config: checker_pipeline_config(), max_attempts: 1})

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}, 1_000

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 valid_checker_payload(loop.id, 1, "fail", "ticket checker failed", %{
                   "checker_step_receipts" => [
                     %{
                       "step_id" => "base-just-lint-and-test",
                       "skill" => "command",
                       "order_index" => 0,
                       "required" => true,
                       "verdict" => "pass",
                       "summary" => "Base pipeline passed."
                     },
                     %{
                       "step_id" => "checker-step-1",
                       "skill" => "pull",
                       "order_index" => 1,
                       "required" => true,
                       "verdict" => "fail",
                       "summary" => "Task loop orchestrator tests failed."
                     }
                   ]
                 }),
                 daemon.name,
                 loop.workspace_id
               )

      refute_receive {:push, _, _, %{"role" => "maker"}}, 100

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :failed

      reloaded_ticket = Tickets.get_ticket!(ticket.id)
      assert reloaded_ticket.status == :halted

      last_failed_receipt =
        get_history(pid, loop.id)
        |> Enum.filter(&(&1.role == "checker" && &1.attempt == 1))
        |> Enum.sort_by(& &1.order_index)
        |> Enum.find(&(&1.required && &1.verdict != "pass"))

      assert last_failed_receipt.step_id == "checker-step-1"
      assert last_failed_receipt.skill == "pull"
      assert last_failed_receipt.verdict == "fail"
      assert last_failed_receipt.summary == "Task loop orchestrator tests failed."
      assert last_failed_receipt.attempt == 1
    end
  end

  describe "task loop: checker fail with retry" do
    test "checker fail retries maker with feedback", %{orchestrator: pid} do
      %{loop: loop, daemon: daemon} = setup_task_loop(pid)

      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-1", "exit_code" => 0},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}, 1_000

      assert :ok =
               handle_attempt_complete(
                 pid,
                 loop.id,
                 valid_checker_payload(loop.id, 1, "fail", "Missing error handling"),
                 daemon.name,
                 loop.workspace_id
               )

      assert_receive {:push, _, loop_id, %{"role" => "maker", "task" => task}}
      assert loop_id == loop.id
      assert task =~ "Missing error handling"

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :running
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
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}

      handle_attempt_complete(
        pid,
        loop.id,
        valid_checker_payload(loop.id, 1, "fail", "Still broken"),
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "maker"}}

      # Attempt 2: maker → checker → fail → exhausted
      handle_attempt_complete(
        pid,
        loop.id,
        %{"session_id" => "maker-2", "exit_code" => 0},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, _, %{"role" => "checker"}}

      handle_attempt_complete(
        pid,
        loop.id,
        valid_checker_payload(loop.id, 2, "fail", "Still broken again"),
        daemon.name,
        loop.workspace_id
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
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker"}}

      # Checker handoff invalid — repair 1
      handle_attempt_complete(
        pid,
        loop_id,
        %{"session_id" => "c1", "handoff_valid" => false, "handoff_error" => "missing json"},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "task" => t1}}
      assert t1 =~ "REPAIR-ONLY MODE"

      # Repair 1 also fails — repair 2
      handle_attempt_complete(
        pid,
        loop_id,
        %{"session_id" => "c2", "handoff_valid" => false, "handoff_error" => "still missing"},
        daemon.name,
        loop.workspace_id
      )

      assert_receive {:push, _, ^loop_id, %{"role" => "checker", "task" => t2}}
      assert t2 =~ "repair round 2"

      # Repair 2 also fails — exceeds max repairs, falls back to retry
      handle_attempt_complete(
        pid,
        loop_id,
        %{"session_id" => "c3", "handoff_valid" => false, "handoff_error" => "still missing"},
        daemon.name,
        loop.workspace_id
      )

      # Should get a new maker attempt (retry)
      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}

      reloaded = Algedonia.Loops.get_loop!(loop_id)
      assert reloaded.status == :running
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

  describe "dispatch gating on repo readiness" do
    test "rejects task loop when repo not ready", %{orchestrator: pid} do
      workspace =
        insert_workspace!(%{
          slug: "gated-ws",
          github_repo_url: "https://github.com/example/repo"
        })

      ticket =
        insert_ticket!(%{
          status: :in_progress,
          workspace_id: workspace.id
        })

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :pending,
          max_attempts: 3
        })

      daemon = insert_daemon!(%{status: :online})

      assert {:error, :repo_not_ready} =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )
    end

    test "allows task loop when repo is ready", %{orchestrator: pid} do
      workspace =
        insert_workspace!(%{
          slug: "ready-ws",
          github_repo_url: "https://github.com/example/repo"
        })

      ticket =
        insert_ticket!(%{
          status: :in_progress,
          workspace_id: workspace.id
        })

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :pending,
          max_attempts: 3
        })

      daemon = insert_daemon!(%{status: :online})

      Algedonia.Daemons.set_repo_status(daemon.name, "ready-ws", %{"status" => "ready"})

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, _, %{"role" => "maker"}}
    end

    test "allows task loop when workspace has no repo URL", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, _, %{"role" => "maker"}}
    end
  end

  describe "start_loop status guard" do
    test "returns {:error, :already_running} for running loop", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :running,
          max_attempts: 3
        })

      daemon = insert_daemon!(%{status: :online})

      assert {:error, :already_running} =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )
    end

    test "returns {:error, :already_running} for passed loop", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :passed, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})

      assert {:error, :already_running} =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )
    end

    test "returns {:error, :already_running} for failed loop", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :failed, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})

      assert {:error, :already_running} =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )
    end

    test "allows starting a pending loop", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})
      daemon = insert_daemon!(%{status: :online})

      assert :ok =
               GenServer.call(
                 pid,
                 {:start_task_loop, loop.id, daemon.name, [workspace_id: loop.workspace_id]}
               )

      assert_receive {:push, _, _, %{"role" => "maker"}}
    end
  end

  describe "ticket halt stops running loops" do
    test "halted ticket stops running loops and sets status to failed", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})
      daemon = insert_daemon!(%{status: :online})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :running,
          assigned_daemon_id: daemon.id,
          max_attempts: 3,
          current_attempt: 1
        })

      # Simulate ticket halted via PubSub
      send(pid, {:ticket_updated, %{ticket | status: :halted}})

      # Give the GenServer time to process
      :sys.get_state(pid)

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :failed
    end

    test "halted ticket ignores already-passed loops", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :passed,
          max_attempts: 3,
          current_attempt: 1
        })

      send(pid, {:ticket_updated, %{ticket | status: :halted}})
      :sys.get_state(pid)

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :passed
    end
  end

  describe "ticket in-progress auto-start" do
    test "in_progress ticket auto-starts first pending loop on available daemon", %{
      orchestrator: pid
    } do
      ticket = insert_ticket!(%{status: :in_progress, title: "IP auto-start pending"})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})
      _daemon = insert_daemon!(%{status: :online})
      loop_id = loop.id

      send(pid, {:ticket_updated, Map.put(ticket, :status, :in_progress)})
      :sys.get_state(pid)

      assert_receive {:push, _, ^loop_id, %{"role" => "maker"}}

      reloaded = Algedonia.Loops.get_loop!(loop.id)
      assert reloaded.status == :running
    end

    test "in_progress ticket with no daemon does not crash", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress, title: "IP no daemon"})

      _loop =
        insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})

      # No daemon inserted

      updated_ticket = %{ticket | status: :in_progress}
      send(pid, {:ticket_updated, updated_ticket})
      # Should not crash
      :sys.get_state(pid)

      refute_receive {:push, _, _, _}, 100
    end

    test "in_progress ticket auto-start ignores hook loops", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress, title: "IP ignore hooks"})

      _hook_loop =
        insert_loop!(%{ticket_id: ticket.id, role: :hook, status: :pending, max_attempts: 3})

      task_loop =
        insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})

      task_loop_id = task_loop.id

      _daemon = insert_daemon!(%{status: :online})

      in_progress_ticket = %{ticket | status: :in_progress}
      send(pid, {:ticket_updated, in_progress_ticket})
      :sys.get_state(pid)

      assert_receive {:push, _, ^task_loop_id, %{"role" => "maker"}}
    end

    test "in_progress ticket auto-start skips non-pending task loops", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress, title: "IP skip passed loops"})

      _passed_task_loop =
        insert_loop!(%{ticket_id: ticket.id, role: :task, status: :passed, max_attempts: 3})

      pending_task_loop =
        insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending, max_attempts: 3})

      pending_task_loop_id = pending_task_loop.id

      _daemon = insert_daemon!(%{status: :online})

      send(pid, {:ticket_updated, ticket |> Map.put(:status, :in_progress)})
      :sys.get_state(pid)

      assert_receive {:push, _, ^pending_task_loop_id, %{"role" => "maker"}}
    end
  end

  describe "step terminal ids" do
    test "returns current and latest step ids from DB", %{orchestrator: pid} do
      ticket = insert_ticket!(%{status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :running})

      {:ok, maker_step} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "completed",
          started_at: ~U[2026-01-01 00:01:00Z]
        })

      {:ok, checker_step} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "checker",
          attempt: 1,
          status: "running",
          started_at: ~U[2026-01-01 00:02:00Z]
        })

      assert GenServer.call(pid, {:current_step_terminal_id, loop.id, loop.workspace_id}) ==
               checker_step.id

      assert GenServer.call(pid, {:latest_step_terminal_id, loop.id, loop.workspace_id}) ==
               checker_step.id

      # Verify maker step is in history
      history = get_history(pid, loop.id)
      assert length(history) == 2
      assert Enum.any?(history, &(&1.id == maker_step.id))
    end

    test "returns nil ids when loop has no steps", %{orchestrator: pid, workspace: workspace} do
      loop_id = Ecto.UUID.generate()
      assert GenServer.call(pid, {:current_step_terminal_id, loop_id, workspace.id}) == nil
      assert GenServer.call(pid, {:latest_step_terminal_id, loop_id, workspace.id}) == nil
    end
  end
end
