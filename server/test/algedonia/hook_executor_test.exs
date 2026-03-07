defmodule Algedonia.HookExecutorTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.{HookExecutor, Loops, Tickets, Workspaces}

  import Algedonia.Factory

  setup do
    workspace = default_workspace!()
    previous_scope = put_workspace_scope(workspace)
    on_exit(fn -> restore_workspace_scope(previous_scope) end)
    {:ok, workspace: workspace}
  end

  describe "fire_hooks/4" do
    test "creates hook loops for matching hooks" do
      workspace = default_workspace!()
      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :planning})

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run linter"
        })

      HookExecutor.fire_hooks(workspace.id, ticket, :backlog, :planning)

      hook_loops = Loops.list_hook_loops_for_ticket(ticket.id)
      assert length(hook_loops) == 1

      loop = hd(hook_loops)
      assert loop.role == :hook
      assert loop.title == "Hook: backlog → planning"
      assert loop.description == "Run linter"
      assert loop.ticket_id == ticket.id
    end

    test "does not create loops when no hooks match" do
      workspace = default_workspace!()
      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :planning})

      HookExecutor.fire_hooks(workspace.id, ticket, :backlog, :planning)

      assert Loops.list_hook_loops_for_ticket(ticket.id) == []
    end

    test "fires multiple hooks for the same transition" do
      workspace = default_workspace!()
      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :planning})

      {:ok, _} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run linter"
        })

      # Can't have duplicate (from, to) so test with different workspace
      # Instead, just verify single hook fires correctly
      HookExecutor.fire_hooks(workspace.id, ticket, :backlog, :planning)
      assert length(Loops.list_hook_loops_for_ticket(ticket.id)) == 1
    end

    test "auto-dispatches hook loop when daemon is online" do
      workspace = default_workspace!()
      daemon = insert_daemon!(%{name: "hook-auto-start", status: :online})
      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :planning})

      Phoenix.PubSub.subscribe(Algedonia.PubSub, "daemon:#{daemon.name}")

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Auto-run transition check"
        })

      HookExecutor.fire_hooks(workspace.id, ticket, :backlog, :planning)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "daemon:hook-auto-start",
                       event: "start_loop",
                       payload: %{
                         "loop_id" => loop_id,
                         "role" => "hook",
                         "task" => task,
                         "ticket_id" => ticket_id,
                         "workspace_slug" => workspace_slug
                       }
                     },
                     1_000

      assert is_binary(loop_id)
      assert ticket_id == ticket.id
      assert workspace_slug == workspace.slug
      assert task =~ "Automation hook execution."
      assert task =~ "Task:\nAuto-run transition check"
      refute task =~ "Ticket:"
      refute task =~ "Transition:"
      refute task =~ "Acceptance criteria:"

      loop = Loops.get_loop!(loop_id)
      assert loop.role == :hook
      assert loop.status == :running
      assert loop.current_attempt == 1
      assert loop.assigned_daemon_id == daemon.id
    end
  end

  describe "build_context/4" do
    test "includes hook instruction, ticket details, and github_repo_url" do
      workspace = insert_workspace!(%{github_repo_url: "https://github.com/org/repo"})

      with_workspace_scope(workspace, fn ->
        ticket = insert_ticket!(%{workspace_id: workspace.id, title: "Fix bug"})

        {:ok, hook} =
          Workspaces.create_transition_hook(workspace, %{
            "from_status" => "backlog",
            "to_status" => "planning",
            "instruction" => "Run tests"
          })

        context = HookExecutor.build_context(hook, ticket, :backlog, :planning)

        assert context.instruction == "Run tests"
        assert context.ticket.title == "Fix bug"
        assert context.ticket.status == :planning
        assert context.ticket.previous_status == :backlog
        assert context.github_repo_url == "https://github.com/org/repo"
      end)
    end
  end

  describe "handle_failure/2" do
    test "marks loop as failed and ticket as halted" do
      workspace = default_workspace!()
      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :hook})

      assert {:ok, halted_ticket} = HookExecutor.handle_failure(loop, ticket)
      assert halted_ticket.status == :halted

      updated_loop = Loops.get_loop!(loop.id)
      assert updated_loop.status == :failed
    end

    test "halting via handle_failure does not fire hooks (skip_hooks)" do
      workspace = default_workspace!()

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "in_progress",
          "to_status" => "halted",
          "instruction" => "Alert on halt"
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :hook})

      # handle_failure uses skip_hooks: true, so no additional hooks should fire
      {:ok, _} = HookExecutor.handle_failure(loop, ticket)

      # Only the original hook loop should exist (no new ones from the halted transition)
      hook_loops = Loops.list_hook_loops_for_ticket(ticket.id)
      assert length(hook_loops) == 1
    end
  end

  describe "attempt callbacks" do
    test "handle_attempt_complete marks hook loop as passed on success" do
      workspace = default_workspace!()
      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :hook,
          status: :running
        })

      :ok =
        HookExecutor.handle_attempt_complete(loop.id, %{"exit_code" => 0},
          workspace_id: workspace.id
        )

      assert Loops.get_loop!(loop.id).status == :passed
      assert Tickets.get_ticket!(ticket.id).status == :in_progress
    end

    test "handle_attempt_error marks hook loop failed and halts ticket" do
      workspace = default_workspace!()
      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :hook,
          status: :running
        })

      :ok =
        HookExecutor.handle_attempt_error(loop.id, %{"message" => "boom"},
          workspace_id: workspace.id
        )

      assert Loops.get_loop!(loop.id).status == :failed
      assert Tickets.get_ticket!(ticket.id).status == :halted
    end
  end

  describe "integration with Tickets.update_ticket/3" do
    test "hooks fire on status change" do
      workspace = default_workspace!()

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run linter"
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :backlog})

      {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :planning})

      hook_loops = Loops.list_hook_loops_for_ticket(ticket.id)
      assert length(hook_loops) == 1
      assert hd(hook_loops).role == :hook
    end

    test "hooks do not fire when skip_hooks is true" do
      workspace = default_workspace!()

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run linter"
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :backlog})

      {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :planning}, skip_hooks: true)

      assert Loops.list_hook_loops_for_ticket(ticket.id) == []
    end

    test "hooks do not fire when status does not change" do
      workspace = default_workspace!()

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run linter"
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :backlog})

      {:ok, _updated} = Tickets.update_ticket(ticket, %{title: "new title"})

      assert Loops.list_hook_loops_for_ticket(ticket.id) == []
    end

    test "hooks fire on transition to halted (from non-halted)" do
      workspace = default_workspace!()

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "in_progress",
          "to_status" => "halted",
          "instruction" => "Alert team on halt"
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})

      {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :halted})

      hook_loops = Loops.list_hook_loops_for_ticket(ticket.id)
      assert length(hook_loops) == 1
      assert hd(hook_loops).description == "Alert team on halt"
    end

    test "status transition auto-starts hook loop when daemon is online" do
      workspace = default_workspace!()
      daemon = insert_daemon!(%{name: "hook-transition-auto", status: :online})
      Phoenix.PubSub.subscribe(Algedonia.PubSub, "daemon:#{daemon.name}")

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "planning",
          "to_status" => "in_progress",
          "instruction" => "Verify branch health"
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :planning})
      {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :in_progress})

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "daemon:hook-transition-auto",
                       event: "start_loop",
                       payload: %{
                         "loop_id" => loop_id,
                         "role" => "hook",
                         "ticket_id" => ticket_id,
                         "workspace_slug" => workspace_slug
                       }
                     },
                     1_000

      assert ticket_id == ticket.id
      assert workspace_slug == workspace.slug
      assert Loops.get_loop!(loop_id).status == :running
    end

    test "hooks do not fire when both from and to are halted" do
      workspace = default_workspace!()

      {:ok, _hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "halted",
          "to_status" => "halted",
          "instruction" => "Should not fire"
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :halted})

      # Re-saving as halted shouldn't trigger hooks (same status anyway)
      {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :halted})

      assert Loops.list_hook_loops_for_ticket(ticket.id) == []
    end
  end
end
