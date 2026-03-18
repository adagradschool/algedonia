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

    poll_fn = fn daemon_name, loop_id, opts ->
      send(test_pid, {:poll_review_pr, daemon_name, loop_id, opts})
    end

    stdin_fn = fn daemon_name, loop_id, data ->
      send(test_pid, {:stdin_input, daemon_name, loop_id, data})
    end

    {:ok, pid} =
      ReviewLoop.start_link(
        push_fn: push_fn,
        poll_fn: poll_fn,
        stdin_fn: stdin_fn,
        name: :test_review_loop
      )

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
      workspace = insert_workspace!(%{slug: "review-ws", name: "Review", prefix: "ALG"})

      ticket =
        insert_ticket!(%{
          status: :in_progress,
          workspace_id: workspace.id,
          title: "Fix login bug"
        })

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
      assert payload["task"] =~ "review and PR shepherd agent"
      assert payload["task"] =~ "feature/ALG-#{ticket.number}"
      assert payload["task"] =~ "ALG-#{ticket.number}: Fix login bug"
    end

    test "does not create duplicate review loops on repeated calls", _ctx do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_progress})

      assert :ok = ReviewLoop.start_review(ticket, name: :test_review_loop)
      assert :ok = ReviewLoop.start_review(ticket, name: :test_review_loop)

      loops = Loops.list_review_loops_for_ticket(ticket.id)
      assert length(loops) == 1
    end

    test "reconcile restart reuses the interrupted review step", _ctx do
      daemon = insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "resume-review", name: "Resume", prefix: "ALG"})

      ticket =
        insert_ticket!(%{
          status: :in_review,
          workspace_id: workspace.id,
          title: "Resume review"
        })

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: workspace.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      {:ok, step} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "review",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      Loops.interrupt_running_steps(loop.id)

      assert :ok =
               ReviewLoop.reconcile_running_reviews(
                 force_start: true,
                 daemon_id: daemon.id,
                 name: :test_review_loop
               )

      daemon_name = daemon.name
      loop_id = loop.id
      assert_receive {:push_start_loop, ^daemon_name, ^loop_id, payload}, @push_timeout
      assert payload["role"] == "review"

      [resumed_step] = Loops.list_steps_for_loop(loop.id)
      assert resumed_step.id == step.id
      assert resumed_step.status == "running"
    end

    test "ticket transition to in_review starts the PR creation review loop once", ctx do
      {:ok, default_pid} = ReviewLoop.start_link(push_fn: ctx.push_fn)

      on_exit(fn ->
        if Process.alive?(default_pid) do
          GenServer.stop(default_pid)
        end
      end)

      daemon = insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "loop-ws", name: "Loop", prefix: "ALG"})

      ticket =
        insert_ticket!(%{
          status: :in_progress,
          workspace_id: workspace.id,
          title: "Ship review flow"
        })

      assert {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :in_review})

      loops = Loops.list_review_loops_for_ticket(ticket.id)
      assert length(loops) == 1

      daemon_name = daemon.name
      assert_receive {:push_start_loop, ^daemon_name, _, payload}, @push_timeout
      assert payload["role"] == "review"
      assert payload["task"] =~ "Suggested PR title"
      assert payload["task"] =~ "ALG-#{ticket.number}: Ship review flow"
    end

    test "backlog -> in_review transition starts the PR creation review loop once", ctx do
      {:ok, default_pid} = ReviewLoop.start_link(push_fn: ctx.push_fn)

      on_exit(fn ->
        if Process.alive?(default_pid) do
          GenServer.stop(default_pid)
        end
      end)

      daemon = insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "loop-ws-backlog", name: "Loop", prefix: "ALG"})

      ticket =
        insert_ticket!(%{
          status: :backlog,
          workspace_id: workspace.id,
          title: "Ship review flow from backlog"
        })

      assert {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :in_review})

      loops = Loops.list_review_loops_for_ticket(ticket.id)
      assert length(loops) == 1

      daemon_name = daemon.name
      assert_receive {:push_start_loop, ^daemon_name, _, payload}, @push_timeout
      assert payload["role"] == "review"
      assert payload["task"] =~ "Suggested PR title"
      assert payload["task"] =~ "ALG-#{ticket.number}: Ship review flow from backlog"
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
    test "poll asks the daemon for merged state, CI state, and feedback changes",
         ctx do
      daemon = insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "poll-ws", name: "Poll", prefix: "ALG"})

      ticket =
        insert_ticket!(%{
          status: :in_review,
          workspace_id: workspace.id,
          title: "Poll reviews",
          review_pr_number: 42
        })

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          agent_link: "/w/poll-ws/tickets/#{ticket.number}/loops/#{String.slice(loop.id, 0, 8)}",
          last_activity_at: DateTime.utc_now()
        })
      end)

      loop_id = loop.id
      send(ctx.review_loop, {:poll_review, loop.id})

      daemon_name = daemon.name
      assert_receive {:poll_review_pr, ^daemon_name, ^loop_id, payload}, @push_timeout
      assert payload["ticket_id"] == ticket.id
      assert payload["pr_number"] == ticket.review_pr_number
      assert payload["workspace_slug"] == workspace.slug
      assert payload["branch_name"] == Tickets.worktree_branch_name(ticket, workspace)
    end

    test "poll still asks the daemon to resolve the PR by branch when linkage is missing",
         ctx do
      daemon = insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "poll-ws", name: "Poll", prefix: "ALG"})

      ticket =
        insert_ticket!(%{
          status: :in_review,
          workspace_id: workspace.id,
          title: "Discover review PR"
        })

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          agent_link: "/w/poll-ws/tickets/#{ticket.number}/loops/#{String.slice(loop.id, 0, 8)}",
          last_activity_at: DateTime.utc_now()
        })
      end)

      send(ctx.review_loop, {:poll_review, loop.id})

      daemon_name = daemon.name
      loop_id = loop.id
      assert_receive {:poll_review_pr, ^daemon_name, ^loop_id, payload}, @push_timeout
      assert payload["ticket_id"] == ticket.id
      assert payload["workspace_slug"] == workspace.slug
      assert payload["branch_name"] == Tickets.worktree_branch_name(ticket, workspace)
      refute Map.has_key?(payload, "pr_number")
    end
  end

  describe "PR navigation comment upsert behavior" do
    test "review prompt includes ticket link, review loop link, and idempotent comment marker",
         _ctx do
      insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "test-ws", name: "Test", prefix: "ALG"})

      ticket =
        insert_ticket!(%{
          status: :in_progress,
          workspace_id: workspace.id,
          title: "Tighten review loop"
        })

      assert :ok = ReviewLoop.start_review(ticket, name: :test_review_loop)

      assert_receive {:push_start_loop, _, _, payload}, @push_timeout
      assert payload["task"] =~ "algedonia-agent-link"
      assert payload["task"] =~ "Algedonia ticket"
      assert payload["task"] =~ "/w/test-ws/tickets/#{ticket.number}"
      assert payload["task"] =~ "Review agent loop"
    end
  end

  describe "server->daemon poll request behavior" do
    test "after attempt_complete, review polling runs through canonical branch lookup", ctx do
      daemon = insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "refresh-ws", name: "Refresh", prefix: "ALG"})
      ticket = insert_ticket!(%{status: :in_review, workspace_id: workspace.id})

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

      daemon_name = daemon.name
      loop_id = loop.id
      assert_receive {:poll_review_pr, ^daemon_name, ^loop_id, poll_payload}, @push_timeout
      assert poll_payload["ticket_id"] == ticket.id
      assert poll_payload["workspace_slug"] == workspace.slug
      assert poll_payload["branch_name"] == Tickets.worktree_branch_name(ticket, workspace)
      refute Map.has_key?(poll_payload, "pr_number")

      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert is_nil(updated_ticket.review_pr_number)
    end
  end

  describe "background polling" do
    test "successful poll updates last_polled_at and nudges the agent only when feedback changed",
         ctx do
      daemon = insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :in_review, review_pr_number: 42})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          feedback_token: nil
        })
      end)

      payload = %{
        "ok" => true,
        "pr_number" => 42,
        "ci_state" => "success",
        "feedback_token" => "changed",
        "polled_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      assert :ok =
               ReviewLoop.handle_pr_status(loop.id, payload,
                 workspace_id: ticket.workspace_id,
                 name: :test_review_loop
               )

      daemon_name = daemon.name
      loop_id = loop.id
      assert_receive {:stdin_input, ^daemon_name, ^loop_id, encoded}, @push_timeout
      assert Base.decode64!(encoded) =~ "pr-review-feedback"

      poll_state = ReviewLoop.poll_state(loop.id, name: :test_review_loop)
      assert %DateTime{} = poll_state.last_polled_at
      assert poll_state.feedback_token == "changed"
    end

    test "successful poll backfills PR linkage discovered by branch", ctx do
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

      :sys.replace_state(ctx.review_loop, fn state ->
        put_in(state, [Access.key(:review_loops), loop.id], %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          feedback_token: nil
        })
      end)

      payload = %{
        "ok" => true,
        "pr_number" => 94,
        "pr_url" => "https://github.com/test/repo/pull/94",
        "ci_state" => "pending",
        "feedback_token" => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "polled_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      assert :ok =
               ReviewLoop.handle_pr_status(loop.id, payload,
                 workspace_id: ticket.workspace_id,
                 name: :test_review_loop
               )

      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.review_pr_number == 94
    end
  end

  describe "manual resume via pull_comments" do
    test "pull_comments nudges the active review agent", ctx do
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

      daemon_name = daemon.name
      loop_id = loop.id
      assert_receive {:stdin_input, ^daemon_name, ^loop_id, encoded}, @push_timeout
      assert Base.decode64!(encoded) =~ "pr-review-feedback"
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

    test "merge via attempt_complete defers ticket completion to pr_status", ctx do
      daemon = insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{slug: "merged-ws", name: "Merged", prefix: "ALG"})
      ticket = insert_ticket!(%{status: :in_review, workspace_id: workspace.id})

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

      payload = %{"session_id" => "sess-1", "exit_code" => 0, "merged" => true}

      assert :ok =
               ReviewLoop.handle_attempt_complete(loop.id, payload,
                 daemon_name: daemon.name,
                 workspace_id: ticket.workspace_id,
                 name: :test_review_loop
               )

      daemon_name = daemon.name
      loop_id = loop.id
      assert_receive {:poll_review_pr, ^daemon_name, ^loop_id, poll_payload}, @push_timeout
      assert poll_payload["workspace_slug"] == workspace.slug
      assert poll_payload["branch_name"] == Tickets.worktree_branch_name(ticket, workspace)

      updated_loop = Loops.get_loop!(loop.id)
      assert updated_loop.status == :running

      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.status == :in_review
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
    test "review_task includes required skill set and PR metadata" do
      workspace = insert_workspace!(%{slug: "ws", name: "WS", prefix: "ALG"})

      ticket =
        insert_ticket!(%{
          status: :in_review,
          workspace_id: workspace.id,
          title: "Refine review flow"
        })

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
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
          %{
            ticket_code: "ALG-#{ticket.number}",
            branch_name: "feature/ALG-#{ticket.number}",
            pr_title: "ALG-#{ticket.number}: Refine review flow",
            pr_description:
              "## Summary\n- Refine the review loop.\n\n## Links\n- Algedonia ticket: /w/ws/tickets/#{ticket.number}\n\n- Review agent loop: /w/ws/tickets/#{ticket.number}/loops/abc12345",
            ticket_link: "/w/ws/tickets/#{ticket.number}",
            agent_link: "/w/ws/tickets/#{ticket.number}/loops/abc12345"
          }
        )

      assert prompt =~ "pull"
      assert prompt =~ "pr-review-feedback"
      assert prompt =~ "algedonia-zen"
      assert prompt =~ "ag"
      assert prompt =~ "Suggested PR title"
      assert prompt =~ "Suggested PR description"
      assert prompt =~ "required CI"
      assert prompt =~ "Do not exit while required CI checks are still pending"
      assert prompt =~ "Human review is required for now"
      assert prompt =~ "Do not merge the PR or enable GitHub auto-merge"
      assert prompt =~ "feature/ALG-#{ticket.number}"
      assert prompt =~ "algedonia-agent-link"
      assert prompt =~ "/w/ws/tickets/#{ticket.number}"
      assert prompt =~ "/w/ws/tickets/#{ticket.number}/loops/abc12345"
      refute prompt =~ "auto-land agent"
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
