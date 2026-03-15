defmodule Algedonia.TicketsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.{Loops, Tickets}
  alias Algedonia.Loops.LoopStep
  import Algedonia.Factory

  describe "create_ticket/1" do
    test "creates a ticket with valid attrs" do
      attrs =
        ticket_attrs(%{title: "New feature"})
        |> Map.delete(:coding_agent)

      assert {:ok, ticket} = Tickets.create_ticket(attrs)
      assert ticket.title == "New feature"
      assert ticket.status == :backlog
      assert ticket.coding_agent == :codex
    end

    test "returns error changeset with invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = Tickets.create_ticket(%{})
    end
  end

  describe "list_tickets/1" do
    test "returns all tickets" do
      t1 = insert_ticket!()
      t2 = insert_ticket!()
      tickets = Tickets.list_tickets()
      ids = Enum.map(tickets, & &1.id)
      assert t1.id in ids
      assert t2.id in ids
    end

    test "filters by status" do
      insert_ticket!(%{status: :backlog})
      insert_ticket!(%{status: :in_progress})

      tickets = Tickets.list_tickets(status: :backlog)
      assert Enum.all?(tickets, &(&1.status == :backlog))
    end

    test "filters by assignee" do
      insert_ticket!(%{assignee: "alice"})
      insert_ticket!(%{assignee: "bob"})

      tickets = Tickets.list_tickets(assignee: "alice")
      assert Enum.all?(tickets, &(&1.assignee == "alice"))
    end

    test "filters by type" do
      insert_ticket!(%{type: :bug})
      insert_ticket!(%{type: :feature})
      insert_ticket!(%{type: :chore})

      tickets = Tickets.list_tickets(type: :bug)
      assert Enum.all?(tickets, &(&1.type == :bug))
      assert length(tickets) == 1
    end

    test "filters by priority" do
      insert_ticket!(%{priority: 1})
      insert_ticket!(%{priority: 2})
      insert_ticket!(%{priority: 1})

      tickets = Tickets.list_tickets(priority: 1)
      assert Enum.all?(tickets, &(&1.priority == 1))
      assert length(tickets) == 2
    end

    test "combines type and priority filters" do
      insert_ticket!(%{type: :bug, priority: 1})
      insert_ticket!(%{type: :bug, priority: 3})
      insert_ticket!(%{type: :feature, priority: 1})

      tickets = Tickets.list_tickets(type: :bug, priority: 1)
      assert length(tickets) == 1
      assert hd(tickets).type == :bug
      assert hd(tickets).priority == 1
    end

    test "sorts by priority" do
      insert_ticket!(%{priority: 5})
      insert_ticket!(%{priority: 1})
      insert_ticket!(%{priority: 3})

      tickets = Tickets.list_tickets(sort_by: :priority, sort_order: :asc)
      priorities = Enum.map(tickets, & &1.priority)
      assert priorities == Enum.sort(priorities)
    end
  end

  describe "list_tickets_by_status/1" do
    test "groups tickets by status" do
      insert_ticket!(%{status: :backlog})
      insert_ticket!(%{status: :backlog})
      insert_ticket!(%{status: :in_progress})

      grouped = Tickets.list_tickets_by_status()
      backlog = Map.get(grouped, :backlog, [])
      in_progress = Map.get(grouped, :in_progress, [])
      assert [_ | [_ | _]] = backlog
      assert [_ | _] = in_progress
    end
  end

  describe "get_ticket!/1" do
    test "returns the ticket" do
      ticket = insert_ticket!()
      assert Tickets.get_ticket!(ticket.id).id == ticket.id
    end

    test "raises on missing" do
      default_workspace!()

      assert_raise Ecto.NoResultsError, fn ->
        Tickets.get_ticket!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_ticket_by_number!/2" do
    test "returns ticket by workspace and number" do
      ticket = insert_ticket!()
      found = Tickets.get_ticket_by_number!(ticket.workspace_id, ticket.number)
      assert found.id == ticket.id
    end

    test "raises when number does not exist" do
      ticket = insert_ticket!()

      assert_raise Ecto.NoResultsError, fn ->
        Tickets.get_ticket_by_number!(ticket.workspace_id, 999_999)
      end
    end

    test "raises when workspace does not match" do
      ticket = insert_ticket!()
      other_workspace = insert_workspace!(%{slug: "other-ws", name: "Other"})

      assert_raise Ecto.NoResultsError, fn ->
        Tickets.get_ticket_by_number!(other_workspace.id, ticket.number)
      end
    end
  end

  describe "update_ticket/2" do
    test "updates with valid attrs" do
      ticket = insert_ticket!()
      assert {:ok, updated} = Tickets.update_ticket(ticket, %{title: "Updated"})
      assert updated.title == "Updated"
    end

    test "returns error changeset with invalid attrs" do
      ticket = insert_ticket!()
      assert {:error, %Ecto.Changeset{}} = Tickets.update_ticket(ticket, %{title: ""})
    end
  end

  describe "update_ticket/2 loop lifecycle transitions" do
    test "entering in_progress ensures a task loop with workspace iteration budget" do
      workspace = insert_workspace!(%{max_iterations: 6})
      ticket = insert_ticket!(%{status: :planning, workspace_id: workspace.id})

      assert {:ok, updated} = Tickets.update_ticket(ticket, %{status: :in_progress})
      assert updated.status == :in_progress

      [task_loop] = Loops.list_task_loops_for_ticket(ticket.id)
      assert task_loop.role == :task
      assert task_loop.status == :pending
      assert task_loop.max_attempts == 6
    end

    test "entering in_progress reuses existing task loop" do
      ticket = insert_ticket!(%{status: :planning})
      existing = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending})

      assert {:ok, _updated} = Tickets.update_ticket(ticket, %{status: :in_progress})

      loops = Loops.list_task_loops_for_ticket(ticket.id)
      assert length(loops) == 1
      assert hd(loops).id == existing.id
    end

    test "moving backward out of in_progress deletes loops and steps" do
      ticket = insert_ticket!(%{status: :in_progress})
      task_loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :running})
      hook_loop = insert_loop!(%{ticket_id: ticket.id, role: :hook, status: :pending})

      {:ok, _task_step} =
        Loops.create_step(%{
          loop_id: task_loop.id,
          role: "maker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok, _hook_step} =
        Loops.create_step(%{
          loop_id: hook_loop.id,
          role: "checker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert {:ok, updated} = Tickets.update_ticket(ticket, %{status: :planning})
      assert updated.status == :planning
      assert Loops.list_loops_for_ticket(ticket.id) == []

      remaining_steps =
        from(s in LoopStep,
          where: s.loop_id in ^[task_loop.id, hook_loop.id]
        )
        |> Repo.aggregate(:count)

      assert remaining_steps == 0
    end

    test "moving in_progress forward keeps loops intact" do
      ticket = insert_ticket!(%{status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :running})

      assert {:ok, updated} = Tickets.update_ticket(ticket, %{status: :halted})
      assert updated.status == :halted
      assert [reloaded] = Loops.list_task_loops_for_ticket(ticket.id)
      assert reloaded.id == loop.id
    end

    test "in_progress -> in_review is a valid transition" do
      ticket = insert_ticket!(%{status: :in_progress})
      assert {:ok, updated} = Tickets.update_ticket(ticket, %{status: :in_review})
      assert updated.status == :in_review
    end

    test "in_review status is included in display_statuses" do
      assert :in_review in Tickets.display_statuses()
    end
  end

  describe "delete_ticket/1" do
    test "deletes the ticket" do
      ticket = insert_ticket!()
      assert {:ok, _} = Tickets.delete_ticket(ticket)

      assert_raise Ecto.NoResultsError, fn ->
        Tickets.get_ticket!(ticket.id)
      end
    end
  end

  describe "update_overview/2" do
    test "persists overview content" do
      ticket = insert_ticket!()
      assert {:ok, updated} = Tickets.update_overview(ticket, "# Overview\nSome content")
      assert updated.overview == "# Overview\nSome content"
      assert Tickets.get_ticket!(ticket.id).overview == "# Overview\nSome content"
    end

    test "returns error on stale ticket" do
      ticket = insert_ticket!()
      Tickets.delete_ticket(ticket)

      assert_raise Ecto.StaleEntryError, fn ->
        Tickets.update_overview(ticket, "content")
      end
    end
  end

  describe "start_work/1" do
    test "creates a loop and returns its id for a planning ticket" do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :planning})
      assert {:ok, loop_id} = Tickets.start_work(ticket)
      assert is_binary(loop_id)
      assert Tickets.get_ticket!(ticket.id).status == :in_progress
    end

    test "creates a loop and returns its id for a halted ticket" do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :halted})
      assert {:ok, loop_id} = Tickets.start_work(ticket)
      assert is_binary(loop_id)
    end

    test "fails early when no online daemon and stays planning" do
      ticket = insert_ticket!(%{status: :planning})

      assert {:error, :no_online_daemon} = Tickets.start_work(ticket)
      assert Tickets.get_ticket!(ticket.id).status == :planning
      assert Algedonia.Loops.list_loops_for_ticket(ticket.id) == []
    end

    test "fails early when daemon repo is not ready and stays planning" do
      workspace =
        insert_workspace!(%{
          github_repo_url: "https://github.com/example/repo"
        })

      insert_daemon!(%{name: "daemon-not-ready", status: :online})
      ticket = insert_ticket!(%{status: :planning, workspace_id: workspace.id})

      assert {:error, :daemon_repo_not_ready} = Tickets.start_work(ticket)
      assert Tickets.get_ticket!(ticket.id).status == :planning
      assert Algedonia.Loops.list_loops_for_ticket(ticket.id) == []
    end

    test "ignores hook loops and returns a task loop" do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :planning})

      hook_loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :hook,
          status: :pending,
          title: "Hook: planning -> in_progress"
        })

      assert {:ok, loop_id} = Tickets.start_work(ticket)
      task_loop = Algedonia.Loops.get_loop!(loop_id)

      assert task_loop.role == :task
      assert task_loop.id != hook_loop.id
      assert Tickets.get_ticket!(ticket.id).status == :in_progress
    end

    test "returns error for backlog ticket" do
      ticket = insert_ticket!(%{status: :backlog})
      assert {:error, :invalid_status} = Tickets.start_work(ticket)
    end

    test "returns error for in_progress ticket" do
      ticket = insert_ticket!(%{status: :in_progress})
      assert {:error, :invalid_status} = Tickets.start_work(ticket)
    end

    test "accepts valid checker config and persists it on the task loop" do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :planning})
      checker_config = [%{"skill" => "pull", "params" => %{"mode" => "rebase"}}]

      assert {:ok, loop_id} = Tickets.start_work(ticket, checker_config: checker_config)

      loop = Loops.get_loop!(loop_id)
      assert loop.checker_config == %{"steps" => checker_config}
      assert Tickets.get_ticket!(ticket.id).status == :in_progress
    end

    test "fails fast with structured errors when checker config is invalid" do
      ticket = insert_ticket!(%{status: :planning})
      checker_config = [%{"skill" => "missing-skill"}]

      assert {:error, {:invalid_checker_config, errors}} =
               Tickets.start_work(ticket, checker_config: checker_config)

      assert Enum.any?(errors, fn error ->
               error.code == "unknown_skill" and error.path == "$[0].skill" and error.index == 0
             end)

      assert Tickets.get_ticket!(ticket.id).status == :planning
      assert Loops.list_loops_for_ticket(ticket.id) == []
    end
  end

  describe "start_planning/1" do
    test "moves backlog ticket to planning" do
      ticket = insert_ticket!(%{status: :backlog})
      assert {:ok, planned} = Tickets.start_planning(ticket)
      assert planned.status == :planning
    end

    test "returns error for non-backlog ticket" do
      ticket = insert_ticket!(%{status: :in_progress})
      assert {:error, :invalid_status} = Tickets.start_planning(ticket)
    end
  end

  describe "start_planning_work/1" do
    test "creates a persisted planning loop and single-step history for planning ticket" do
      ticket = insert_ticket!(%{status: :planning, title: "Plan this"})

      assert {:ok, loop_id} = Tickets.start_planning_work(ticket)
      loop = Algedonia.Loops.get_loop!(loop_id)
      steps = Algedonia.Loops.list_steps_for_loop(loop_id)

      assert loop.role == :planning
      assert loop.ticket_id == ticket.id
      assert length(steps) == 1
      assert hd(steps).role == "maker"
      assert hd(steps).attempt == 1
      assert hd(steps).status == "running"
    end

    test "reuses the first persisted planning loop deterministically" do
      ticket = insert_ticket!(%{status: :planning})

      first =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :planning,
          title: "Planning A"
        })

      _second =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :planning,
          title: "Planning B"
        })

      assert {:ok, first_loop_id} = Tickets.start_planning_work(ticket)
      assert first_loop_id == first.id
    end

    test "works for halted tickets" do
      halted_ticket = insert_ticket!(%{status: :halted})
      assert {:ok, halted_loop_id} = Tickets.start_planning_work(halted_ticket)
      assert Algedonia.Loops.get_loop!(halted_loop_id).role == :planning
    end

    test "rejects invalid status" do
      ticket = insert_ticket!(%{status: :backlog})
      assert {:error, :invalid_status} = Tickets.start_planning_work(ticket)
    end
  end

  describe "export_markdown/1" do
    test "renders full ticket with all sections and comments" do
      ticket =
        insert_ticket!(%{
          title: "Add feature X",
          status: :in_progress,
          type: :feature,
          priority: 2,
          assignee: "alice",
          coding_agent: :claude_code,
          description: "Build feature X",
          acceptance_criteria: "- Passes tests",
          rubric: "| # | Rule |\n|---|------|"
        })

      {:ok, updated} = Tickets.update_overview(ticket, "High-level overview")
      ticket = Tickets.get_ticket!(updated.id)

      {:ok, c1} =
        Tickets.create_comment(%{ticket_id: ticket.id, author: "alice", body: "Looks good"})

      {:ok, _r1} =
        Tickets.create_comment(%{
          ticket_id: ticket.id,
          author: "bob",
          body: "I agree",
          parent_id: c1.id
        })

      comments = Tickets.list_comments(ticket.id)
      ticket = %{ticket | comments: comments}

      md = Tickets.export_markdown(ticket)

      assert md =~ "# ##{ticket.number}: Add feature X"
      assert md =~ "| Status | in progress |"
      assert md =~ "| Type | feature |"
      assert md =~ "| Priority | P2 |"
      assert md =~ "| Assignee | alice |"
      assert md =~ "| Coding Agent | claude_code |"
      assert md =~ "## Description\n\nBuild feature X"
      assert md =~ "## Acceptance Criteria\n\n- Passes tests"
      assert md =~ "## Rubric"
      assert md =~ "## Overview\n\nHigh-level overview"
      assert md =~ "## Comments"
      assert md =~ "### alice"
      assert md =~ "Looks good"
      assert md =~ "> #### bob"
      assert md =~ "> I agree"
    end

    test "omits empty optional sections" do
      ticket =
        insert_ticket!(%{
          title: "Sparse ticket",
          description: nil,
          acceptance_criteria: nil,
          rubric: nil
        })

      ticket = %{ticket | comments: [], overview: nil}
      md = Tickets.export_markdown(ticket)

      assert md =~ "# ##{ticket.number}: Sparse ticket"
      refute md =~ "## Description"
      refute md =~ "## Acceptance Criteria"
      refute md =~ "## Rubric"
      refute md =~ "## Overview"
      refute md =~ "## Comments"
    end

    test "orders comments chronologically with nested replies" do
      ticket = insert_ticket!()

      {:ok, c1} =
        Tickets.create_comment(%{ticket_id: ticket.id, author: "alice", body: "First"})

      {:ok, _c2} =
        Tickets.create_comment(%{ticket_id: ticket.id, author: "bob", body: "Second"})

      {:ok, _r1} =
        Tickets.create_comment(%{
          ticket_id: ticket.id,
          author: "carol",
          body: "Reply to first",
          parent_id: c1.id
        })

      comments = Tickets.list_comments(ticket.id)
      ticket = %{ticket | comments: comments}
      md = Tickets.export_markdown(ticket)

      first_pos = :binary.match(md, "First") |> elem(0)
      reply_pos = :binary.match(md, "Reply to first") |> elem(0)
      second_pos = :binary.match(md, "### bob") |> elem(0)

      assert first_pos < reply_pos
      assert reply_pos < second_pos
    end
  end

  describe "resolve_land_mode/2" do
    test "returns ticket override when set" do
      ticket = insert_ticket!(%{land_mode: :auto_land})
      workspace = Algedonia.Workspaces.get_workspace!(ticket.workspace_id)
      assert Tickets.resolve_land_mode(ticket, workspace) == :auto_land
    end

    test "falls back to workspace default when ticket has no override" do
      workspace =
        insert_workspace!(%{
          defaults: %{"land_mode" => "auto_land"}
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id})
      assert Tickets.resolve_land_mode(ticket, workspace) == :auto_land
    end

    test "falls back to review_gate when neither ticket nor workspace specify" do
      workspace = insert_workspace!(%{defaults: %{}})
      ticket = insert_ticket!(%{workspace_id: workspace.id})
      assert Tickets.resolve_land_mode(ticket, workspace) == :review_gate
    end

    test "ticket override takes precedence over workspace default" do
      workspace =
        insert_workspace!(%{
          defaults: %{"land_mode" => "auto_land"}
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, land_mode: :review_gate})
      assert Tickets.resolve_land_mode(ticket, workspace) == :review_gate
    end
  end

  describe "land_mode loop creation precedence" do
    test "loop gets ticket override land_mode" do
      insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{defaults: %{"land_mode" => "review_gate"}})

      ticket =
        insert_ticket!(%{status: :planning, workspace_id: workspace.id, land_mode: :auto_land})

      assert {:ok, loop_id} = Tickets.start_work(ticket)
      loop = Loops.get_loop!(loop_id)
      assert loop.land_mode == "auto_land"
    end

    test "loop gets workspace default land_mode when ticket has no override" do
      insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{defaults: %{"land_mode" => "auto_land"}})
      ticket = insert_ticket!(%{status: :planning, workspace_id: workspace.id})

      assert {:ok, loop_id} = Tickets.start_work(ticket)
      loop = Loops.get_loop!(loop_id)
      assert loop.land_mode == "auto_land"
    end

    test "loop gets review_gate when neither ticket nor workspace specify" do
      insert_daemon!(%{status: :online})
      workspace = insert_workspace!(%{defaults: %{}})
      ticket = insert_ticket!(%{status: :planning, workspace_id: workspace.id})

      assert {:ok, loop_id} = Tickets.start_work(ticket)
      loop = Loops.get_loop!(loop_id)
      assert loop.land_mode == "review_gate"
    end
  end

  describe "ticket land_mode validation" do
    test "accepts valid land_mode values" do
      ticket = insert_ticket!()
      assert {:ok, updated} = Tickets.update_ticket(ticket, %{land_mode: :auto_land})
      assert updated.land_mode == :auto_land

      assert {:ok, updated} = Tickets.update_ticket(updated, %{land_mode: :review_gate})
      assert updated.land_mode == :review_gate
    end

    test "rejects invalid land_mode value" do
      ticket = insert_ticket!()
      assert {:error, changeset} = Tickets.update_ticket(ticket, %{land_mode: :invalid_mode})
      assert errors_on(changeset).land_mode
    end

    test "allows clearing land_mode to nil (inherited)" do
      ticket = insert_ticket!(%{land_mode: :auto_land})
      assert {:ok, updated} = Tickets.update_ticket(ticket, %{land_mode: nil})
      assert updated.land_mode == nil
    end

    test "invalid land_mode does not mutate existing loops" do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{status: :planning, land_mode: :auto_land})
      {:ok, loop_id} = Tickets.start_work(ticket)
      loop_before = Loops.get_loop!(loop_id)

      ticket = Tickets.get_ticket!(ticket.id)
      assert {:error, _} = Tickets.update_ticket(ticket, %{land_mode: :invalid_mode})

      loop_after = Loops.get_loop!(loop_id)
      assert loop_after.land_mode == loop_before.land_mode
    end
  end

  describe "search_tickets_grouped/1" do
    test "returns grouped tickets with count" do
      insert_ticket!(%{status: :backlog, title: "Task A"})
      insert_ticket!(%{status: :in_progress, title: "Task B"})

      result = Tickets.search_tickets_grouped([])
      assert %{grouped: grouped, count: count} = result
      assert is_map(grouped)
      assert count >= 2
    end

    test "filters by text query" do
      insert_ticket!(%{status: :backlog, title: "Alpha migration"})
      insert_ticket!(%{status: :backlog, title: "Beta cleanup"})

      result = Tickets.search_tickets_grouped(query: "alpha")
      backlog = Map.get(result.grouped, :backlog, [])
      assert length(backlog) == 1
      assert hd(backlog).title == "Alpha migration"
    end

    test "returns zero count when no matches" do
      insert_ticket!(%{status: :backlog, title: "Something"})

      result = Tickets.search_tickets_grouped(query: "nonexistent_xyz")
      assert result.count == 0
    end
  end
end
