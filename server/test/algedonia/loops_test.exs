defmodule Algedonia.LoopsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Loops
  import Algedonia.Factory

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
      dag = insert_dag!()

      assert {:ok, loop} =
               Loops.create_loop(%{title: "New loop", dag_id: dag.id, role: :task})

      assert loop.title == "New loop"
      assert loop.status == :pending
      assert loop.role == :task
    end

    test "fails without required fields" do
      assert {:error, changeset} = Loops.create_loop(%{})
      assert errors_on(changeset).title
    end
  end

  describe "update_loop_status/2" do
    test "updates status and broadcasts" do
      loop = insert_loop!()
      dag = Algedonia.Repo.preload(loop, dag: :ticket).dag
      Algedonia.Dags.subscribe(dag.ticket_id)

      assert {:ok, updated} = Loops.update_loop_status(loop, :running_maker)
      assert updated.status == :running_maker
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
    test "returns loop with dag and ticket preloaded" do
      ticket = insert_ticket!(%{title: "Preload test"})
      dag = insert_dag!(%{ticket_id: ticket.id})
      loop = insert_loop!(%{dag_id: dag.id})

      loaded = Loops.get_loop_with_ticket!(loop.id)
      assert loaded.id == loop.id
      assert loaded.dag.id == dag.id
      assert loaded.dag.ticket.id == ticket.id
      assert loaded.dag.ticket.title == "Preload test"
    end

    test "raises for nonexistent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Loops.get_loop_with_ticket!(Ecto.UUID.generate())
      end
    end
  end

  describe "preload_ticket/1" do
    test "preloads dag and ticket on a loop struct" do
      ticket = insert_ticket!(%{title: "Preload ticket"})
      dag = insert_dag!(%{ticket_id: ticket.id})
      loop = insert_loop!(%{dag_id: dag.id})

      # Fresh from DB without preloads
      bare = Loops.get_loop!(loop.id)
      assert %Ecto.Association.NotLoaded{} = bare.dag

      preloaded = Loops.preload_ticket(bare)
      assert preloaded.dag.ticket.title == "Preload ticket"
    end
  end
end
