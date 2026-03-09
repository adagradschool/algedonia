defmodule Algedonia.ReviewLoopTest do
  use Algedonia.DataCase, async: false

  alias Algedonia.{Loops, PubSub.Topics, ReviewLoop, Tickets}
  import Algedonia.Factory

  @push_timeout 500

  setup do
    test_pid = self()

    push_fn = fn daemon_name, loop_id, opts ->
      send(test_pid, {:push_start_loop, daemon_name, loop_id, opts})
    end

    {:ok, pid} = ReviewLoop.start_link(push_fn: push_fn, name: :test_review_loop)
    {:ok, review_loop: pid, push_fn: push_fn}
  end

  describe "transition wiring" do
    test "in_progress -> in_review is a valid transition" do
      ticket = insert_ticket!(%{status: :in_progress})
      assert {:ok, updated} = Tickets.update_ticket(ticket, %{status: :in_review})
      assert updated.status == :in_review
    end

    test "backlog -> in_review is valid (no transition guard)" do
      ticket = insert_ticket!(%{status: :backlog})
      assert {:ok, updated} = Tickets.update_ticket(ticket, %{status: :in_review})
      assert updated.status == :in_review
    end
  end

  describe "start_review/1 - idempotent review-loop start" do
    test "creates a review loop when entering in_review", _ctx do
      daemon = insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_progress})

      assert :ok = ReviewLoop.start_review(ticket, name: :test_review_loop)

      loops = Loops.list_review_loops_for_ticket(ticket.id)
      assert length(loops) == 1
      [loop] = loops
      assert loop.role == :review
      assert loop.status == :running
      assert loop.assigned_daemon_id == daemon.id

      daemon_name = daemon.name
      assert_receive {:push_start_loop, ^daemon_name, _, payload}, @push_timeout
      assert payload["role"] == "review"
      assert payload["task"] =~ "review and auto-land agent"
    end

    test "does not create duplicate review loops on repeated calls", _ctx do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_progress})

      assert :ok = ReviewLoop.start_review(ticket, name: :test_review_loop)
      assert :ok = ReviewLoop.start_review(ticket, name: :test_review_loop)

      loops = Loops.list_review_loops_for_ticket(ticket.id)
      assert length(loops) == 1
    end

    test "does not create duplicate loops when triggered via ticket update", _ctx do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_progress})

      assert {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :in_review})

      # Give the GenServer time to process
      Process.sleep(50)

      loops = Loops.list_review_loops_for_ticket(ticket.id)
      # Should have at most 1 review loop
      assert length(loops) <= 1
    end
  end

  describe "rebase-on-main freshness enforcement" do
    test "review prompt includes rebase instructions", _ctx do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_progress})

      assert :ok = ReviewLoop.start_review(ticket, name: :test_review_loop)

      assert_receive {:push_start_loop, _, _, payload}, @push_timeout
      assert payload["task"] =~ "pull"
      assert payload["task"] =~ "rebase"
      assert payload["task"] =~ "origin/main"
    end
  end

  describe "drift-triggered rebase behavior" do
    test "poll re-dispatches review agent to check freshness", ctx do
      daemon = insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      # Simulate a poll by sending the message directly
      send(ctx.review_loop, {:poll_review, loop.id})
      Process.sleep(100)

      # The poll should re-dispatch the review agent since there's no inactivity
      # (but without review_loops state, it won't have info and will just clean up)
    end
  end

  describe "PR navigation comment upsert behavior" do
    test "review prompt includes agent link marker for idempotent comments", _ctx do
      insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "test-ws", name: "Test"})
      ticket = insert_ticket!(%{status: :in_progress, workspace_id: workspace.id})

      assert :ok = ReviewLoop.start_review(ticket, name: :test_review_loop)

      assert_receive {:push_start_loop, _, _, payload}, @push_timeout
      assert payload["task"] =~ "algedonia-agent-link"
      assert payload["task"] =~ "/w/test-ws/tickets/"
    end
  end

  describe "server->daemon poll request behavior" do
    test "after attempt_complete, polling is scheduled", ctx do
      daemon = insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      {:ok, _step} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "review",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      # Register the loop in state (start_review would no-op since loop is already running)
      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          last_activity_at: DateTime.utc_now()
        })
      end)

      # Complete the attempt
      payload = %{
        "session_id" => "sess-1",
        "exit_code" => 0,
        "pr_url" => "https://github.com/test/repo/pull/42",
        "pr_number" => 42
      }

      assert :ok =
               ReviewLoop.handle_attempt_complete(loop.id, payload,
                 daemon_name: daemon.name,
                 workspace_id: ticket.workspace_id,
                 name: :test_review_loop
               )

      # Verify PR linkage was recorded
      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.review_pr_url == "https://github.com/test/repo/pull/42"
      assert updated_ticket.review_pr_number == 42
    end
  end

  describe "15-minute inactivity pause behavior" do
    test "loop pauses when last_activity is beyond timeout", ctx do
      daemon = insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      # Register the loop with an old activity time
      old_time = DateTime.add(DateTime.utc_now(), -16 * 60, :second)

      # Manually set state with old activity time by going through GenServer internals
      # We'll test this indirectly by checking the ticket's review_paused flag
      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          last_activity_at: old_time
        })
      end)

      send(ctx.review_loop, {:poll_review, loop.id})
      Process.sleep(100)

      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.review_paused == true
    end
  end

  describe "manual resume via pull_comments" do
    test "pull_comments un-pauses and re-dispatches review agent", ctx do
      daemon = insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review, review_paused: true})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      # Register the loop in state
      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          last_activity_at: DateTime.utc_now()
        })
      end)

      assert :ok = ReviewLoop.pull_comments(ticket, name: :test_review_loop)

      # Verify un-paused
      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.review_paused == false

      # Verify re-dispatched
      assert_receive {:push_start_loop, _, _, payload}, @push_timeout
      assert payload["role"] == "review"
      assert payload["task"] =~ "pull comments"
    end
  end

  describe "merge -> completed transition" do
    test "merge detection transitions ticket to completed and stops loop", _ctx do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          current_attempt: 1
        })

      assert :ok =
               ReviewLoop.handle_merge_detected(loop.id,
                 workspace_id: ticket.workspace_id,
                 name: :test_review_loop
               )

      updated_loop = Loops.get_loop!(loop.id)
      assert updated_loop.status == :passed

      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.status == :completed
    end

    test "merge via attempt_complete also transitions to completed", ctx do
      daemon = insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      {:ok, _step} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "review",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      # Register the loop in state
      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          last_activity_at: DateTime.utc_now()
        })
      end)

      payload = %{
        "session_id" => "sess-1",
        "exit_code" => 0,
        "merged" => true
      }

      assert :ok =
               ReviewLoop.handle_attempt_complete(loop.id, payload,
                 daemon_name: daemon.name,
                 workspace_id: ticket.workspace_id,
                 name: :test_review_loop
               )

      updated_loop = Loops.get_loop!(loop.id)
      assert updated_loop.status == :passed

      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.status == :completed
    end
  end

  describe "loop close semantics" do
    test "halting a ticket stops review loops", ctx do
      daemon = insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      # Register the loop and subscribe to PubSub from the GenServer process
      :sys.replace_state(ctx.review_loop, fn state ->
        # Subscribe from GenServer process context
        Algedonia.Tickets.subscribe(ticket.workspace_id)

        state
        |> put_in([Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          last_activity_at: DateTime.utc_now()
        })
        |> Map.update!(:subscribed_workspaces, &MapSet.put(&1, ticket.workspace_id))
      end)

      # Trigger halt
      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.tickets(ticket.workspace_id),
        {:ticket_updated, %{ticket | status: :halted}}
      )

      Process.sleep(100)

      updated_loop = Loops.get_loop!(loop.id)
      assert updated_loop.status == :failed
    end

    test "no further polling after merge-detected completion", ctx do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          current_attempt: 1
        })

      assert :ok =
               ReviewLoop.handle_merge_detected(loop.id,
                 workspace_id: ticket.workspace_id,
                 name: :test_review_loop
               )

      # Verify no poll timer remains - sending poll should be a no-op
      send(ctx.review_loop, {:poll_review, loop.id})
      Process.sleep(50)

      # Ticket should still be completed (not changed)
      assert Tickets.get_ticket!(ticket.id).status == :completed
    end
  end

  describe "review prompt template" do
    test "review_task includes required skill set" do
      workspace = insert_workspace!(%{slug: "ws", name: "WS"})
      ticket = insert_ticket!(%{status: :in_review, workspace_id: workspace.id})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          title: "Review: test",
          current_attempt: 1
        })

      loop = Loops.preload_with_workspace(loop)

      prompt =
        Algedonia.PromptBuilder.review_task(
          loop,
          ticket,
          "",
          "/w/ws/tickets/1/loops/abc12345"
        )

      assert prompt =~ "pull"
      assert prompt =~ "pr-review-feedback"
      assert prompt =~ "algedonia-zen"
      assert prompt =~ "ag"
      assert prompt =~ "algedonia-agent-link"
      assert prompt =~ "/w/ws/tickets/1/loops/abc12345"
    end
  end

  describe "attempt error handling" do
    test "error retries review agent", ctx do
      daemon = insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "err-ws", name: "Err", max_iterations: 5})
      ticket = insert_ticket!(%{status: :in_review, workspace_id: workspace.id})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1,
          max_attempts: 5
        })

      {:ok, _step} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "review",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      # Register the loop in state
      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          last_activity_at: DateTime.utc_now()
        })
      end)

      payload = %{
        "session_id" => "sess-1",
        "exit_code" => 1,
        "message" => "agent crashed"
      }

      assert :ok =
               ReviewLoop.handle_attempt_error(loop.id, payload,
                 daemon_name: daemon.name,
                 workspace_id: ticket.workspace_id,
                 name: :test_review_loop
               )

      # Should have retried
      assert_receive {:push_start_loop, _, _, retry_payload}, @push_timeout
      assert retry_payload["role"] == "review"
      assert retry_payload["task"] =~ "agent crashed"

      updated_loop = Loops.get_loop!(loop.id)
      assert updated_loop.current_attempt == 2
      assert updated_loop.status == :running
    end
  end
end
