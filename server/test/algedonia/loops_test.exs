defmodule Algedonia.LoopsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Loops
  import Algedonia.Factory

  setup do
    workspace = insert_workspace!(%{slug: "loops-test-#{System.unique_integer([:positive])}"})
    Process.put(:default_workspace, workspace)
    previous_scope = put_workspace_scope(workspace)

    on_exit(fn ->
      Process.delete(:default_workspace)
      restore_workspace_scope(previous_scope)
    end)

    {:ok, workspace: workspace}
  end

  describe "get_loop!/1" do
    test "returns the loop with given id" do
      loop = insert_loop!(%{title: "Test loop"})
      assert Loops.get_loop!(loop.id).id == loop.id
    end

    test "raises for nonexistent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Loops.get_loop!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_loop/1" do
    test "returns nil for nonexistent id" do
      assert is_nil(Loops.get_loop(Ecto.UUID.generate()))
    end
  end

  describe "create_loop/1" do
    test "creates a loop with valid attrs" do
      ticket = insert_ticket!()

      assert {:ok, loop} =
               Loops.create_loop(%{
                 title: "New loop",
                 ticket_id: ticket.id,
                 workspace_id: ticket.workspace_id,
                 role: :task
               })

      assert loop.title == "New loop"
      assert loop.status == :pending
      assert loop.role == :task
    end

    test "accepts planning as a valid loop role" do
      ticket = insert_ticket!()

      assert {:ok, loop} =
               Loops.create_loop(%{
                 title: "Planning loop",
                 ticket_id: ticket.id,
                 workspace_id: ticket.workspace_id,
                 role: :planning
               })

      assert loop.role == :planning
    end

    test "rejects invalid loop role in changeset" do
      ticket = insert_ticket!()

      assert {:error, changeset} =
               Loops.create_loop(%{
                 title: "Invalid role",
                 ticket_id: ticket.id,
                 role: :invalid
               })

      assert errors_on(changeset).role
    end

    test "database rejects invalid role values outside schema enum" do
      ticket = insert_ticket!()
      now = DateTime.utc_now()

      assert_raise Postgrex.Error, ~r/loops_role_check/, fn ->
        Algedonia.Repo.query!(
          """
          INSERT INTO loops (id, workspace_id, ticket_id, title, role, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, 'invalid_role', $5, $5)
          """,
          [
            Ecto.UUID.generate() |> Ecto.UUID.dump!(),
            ticket.workspace_id |> Ecto.UUID.dump!(),
            ticket.id |> Ecto.UUID.dump!(),
            "raw invalid",
            now
          ]
        )
      end
    end

    test "fails without required fields" do
      assert {:error, changeset} = Loops.create_loop(%{})
      assert errors_on(changeset).title
      assert errors_on(changeset).workspace_id
    end
  end

  describe "update_loop_status/2" do
    test "updates status and broadcasts" do
      loop = insert_loop!()
      Loops.subscribe_ticket_loops(loop.workspace_id, loop.ticket_id)

      assert {:ok, updated} = Loops.update_loop_status(loop, :running)
      assert updated.status == :running
      assert_receive {:loop_status_changed, _}
    end
  end

  describe "update_loop/2" do
    test "updates arbitrary attributes" do
      loop = insert_loop!()

      assert {:ok, updated} = Loops.update_loop(loop, %{current_attempt: 2})
      assert updated.current_attempt == 2
    end
  end

  describe "get_loop_with_ticket!/1" do
    test "returns loop with ticket preloaded" do
      ticket = insert_ticket!(%{title: "Preload test"})
      loop = insert_loop!(%{ticket_id: ticket.id})

      loaded = Loops.get_loop_with_ticket!(loop.id)
      assert loaded.id == loop.id
      assert loaded.ticket.id == ticket.id
      assert loaded.ticket.title == "Preload test"
    end

    test "raises for nonexistent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Loops.get_loop_with_ticket!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_step/1" do
    test "creates a step with valid attrs" do
      loop = insert_loop!()

      assert {:ok, step} =
               Loops.create_step(%{
                 loop_id: loop.id,
                 role: "maker",
                 attempt: 1,
                 status: "running",
                 started_at: DateTime.utc_now()
               })

      assert step.role == "maker"
      assert step.attempt == 1
      assert step.status == "running"
    end

    test "fails without required fields" do
      assert {:error, changeset} = Loops.create_step(%{})
      assert errors_on(changeset).loop_id
      assert errors_on(changeset).role
    end
  end

  describe "complete_step/2" do
    test "completes a step with verdict and feedback" do
      loop = insert_loop!()

      {:ok, step} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "checker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert {:ok, completed} =
               Loops.complete_step(step, %{
                 status: "completed",
                 verdict: "pass",
                 feedback: "All good"
               })

      assert completed.status == "completed"
      assert completed.verdict == "pass"
      assert completed.finished_at
    end
  end

  describe "list_steps_for_loop/1" do
    test "returns steps ordered by started_at" do
      loop = insert_loop!()
      now = DateTime.utc_now()

      {:ok, _s1} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "completed",
          started_at: DateTime.add(now, -10, :second)
        })

      {:ok, _s2} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "checker",
          attempt: 1,
          status: "running",
          started_at: now
        })

      steps = Loops.list_steps_for_loop(loop.id)
      assert length(steps) == 2
      assert hd(steps).role == "maker"
      assert List.last(steps).role == "checker"
    end
  end

  describe "current_phase/1" do
    test "returns latest step role" do
      loop = insert_loop!()

      {:ok, _} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "completed",
          started_at: DateTime.add(DateTime.utc_now(), -10, :second)
        })

      {:ok, _} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "checker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert Loops.current_phase(loop.id) == "checker"
    end

    test "returns nil when no steps" do
      assert is_nil(Loops.current_phase(Ecto.UUID.generate()))
    end
  end

  describe "complete_last_running/4" do
    test "completes the matching running step" do
      loop = insert_loop!()

      {:ok, _} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert {:ok, completed} =
               Loops.complete_last_running(loop.id, "maker", 1, %{
                 status: "completed",
                 exit_code: 0
               })

      assert completed.status == "completed"
      assert completed.exit_code == 0
    end

    test "returns :not_found when no matching step" do
      assert :not_found = Loops.complete_last_running(Ecto.UUID.generate(), "maker", 1, %{})
    end
  end

  describe "active_loop_info_for_tickets/1" do
    test "returns step role as stage when steps exist" do
      ticket = insert_ticket!(%{status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, status: :running, current_attempt: 1})
      now = DateTime.utc_now()

      {:ok, _} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "completed",
          started_at: DateTime.add(now, -10, :second)
        })

      {:ok, _} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "checker",
          attempt: 1,
          status: "running",
          started_at: now
        })

      info = Loops.active_loop_info_for_tickets([ticket.id])
      assert %{stage: "checker", attempt: 1, loop_id: _} = info[ticket.id]
    end

    test "returns 'pending' stage when loop has no steps" do
      ticket = insert_ticket!(%{status: :in_progress})
      _loop = insert_loop!(%{ticket_id: ticket.id, status: :running, current_attempt: 1})

      info = Loops.active_loop_info_for_tickets([ticket.id])
      assert %{stage: "pending", attempt: 1} = info[ticket.id]
    end

    test "returns 'maker' stage for maker step" do
      ticket = insert_ticket!(%{status: :in_progress})
      loop = insert_loop!(%{ticket_id: ticket.id, status: :running, current_attempt: 1})

      {:ok, _} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      info = Loops.active_loop_info_for_tickets([ticket.id])
      assert %{stage: "maker", attempt: 1} = info[ticket.id]
    end

    test "returns empty map for empty input" do
      assert Loops.active_loop_info_for_tickets([]) == %{}
    end
  end

  describe "preload_ticket/1" do
    test "preloads ticket on a loop struct" do
      ticket = insert_ticket!(%{title: "Preload ticket"})
      loop = insert_loop!(%{ticket_id: ticket.id})

      # Fresh from DB without preloads
      bare = Loops.get_loop!(loop.id)
      assert %Ecto.Association.NotLoaded{} = bare.ticket

      preloaded = Loops.preload_ticket(bare)
      assert preloaded.ticket.title == "Preload ticket"
    end
  end
end
