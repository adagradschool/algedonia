defmodule Algedonia.QueueTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Tickets

  import Algedonia.Factory

  describe "queue dependency and ordering" do
    test "persists blocked_by and keeps dependents non-dispatchable until blockers are completed" do
      workspace = default_workspace!()

      assert {:ok, blocker} =
               Tickets.create_ticket_for_workspace(workspace, %{
                 "title" => "Blocker",
                 "type" => "bug"
               })

      assert {:ok, dependent} =
               Tickets.create_ticket_for_workspace(workspace, %{
                 "title" => "Dependent",
                 "type" => "feature",
                 "blocked_by" => [blocker.id]
               })

      reloaded = Tickets.get_ticket!(dependent.id)
      assert reloaded.blocked_by == [blocker.id]

      state = Tickets.queue_state_for_tickets(workspace.id, [dependent.id])
      assert state[dependent.id].dispatchable == false

      assert {:ok, _updated} = Tickets.update_ticket(blocker, %{status: :completed})

      state = Tickets.queue_state_for_tickets(workspace.id, [dependent.id])
      assert state[dependent.id].dispatchable == true
    end

    test "returns validation error for invalid blocker references" do
      workspace = default_workspace!()
      missing_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Tickets.create_ticket_for_workspace(workspace, %{
                 "title" => "Dependent",
                 "type" => "feature",
                 "blocked_by" => [missing_id]
               })

      assert "contains invalid blocker references" in errors_on(changeset).blocked_by
    end

    test "rejects dependency cycles with no partial persistence" do
      workspace = default_workspace!()

      assert {:ok, a} =
               Tickets.create_ticket_for_workspace(workspace, %{"title" => "A", "type" => "bug"})

      assert {:ok, b} =
               Tickets.create_ticket_for_workspace(workspace, %{"title" => "B", "type" => "bug"})

      assert {:ok, _} = Tickets.update_ticket(a, %{blocked_by: [b.id]})

      assert {:error, changeset} = Tickets.update_ticket(b, %{blocked_by: [a.id]})
      assert "creates a dependency cycle" in errors_on(changeset).blocked_by

      assert Tickets.get_ticket!(a.id).blocked_by == [b.id]
      assert Tickets.get_ticket!(b.id).blocked_by == []
    end

    test "reorder_queue persists explicit positions without mutating ticket identity" do
      workspace = default_workspace!()

      assert {:ok, first} =
               Tickets.create_ticket_for_workspace(workspace, %{
                 "title" => "First",
                 "type" => "bug"
               })

      assert {:ok, second} =
               Tickets.create_ticket_for_workspace(workspace, %{
                 "title" => "Second",
                 "type" => "bug"
               })

      assert {:ok, third} =
               Tickets.create_ticket_for_workspace(workspace, %{
                 "title" => "Third",
                 "type" => "bug"
               })

      original_numbers = %{
        first.id => first.number,
        second.id => second.number,
        third.id => third.number
      }

      assert {:ok, queue} = Tickets.reorder_queue(workspace.id, [third.id, first.id, second.id])

      assert Enum.map(queue, & &1.ticket_id) == [third.id, first.id, second.id]
      assert Enum.map(queue, & &1.position) == [0, 1, 2]

      assert Tickets.get_ticket!(first.id).number == original_numbers[first.id]
      assert Tickets.get_ticket!(second.id).number == original_numbers[second.id]
      assert Tickets.get_ticket!(third.id).number == original_numbers[third.id]
    end
  end
end
