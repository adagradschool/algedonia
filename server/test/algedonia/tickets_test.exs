defmodule Algedonia.TicketsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Tickets
  import Algedonia.Factory

  describe "create_ticket/1" do
    test "creates a ticket with valid attrs" do
      attrs = ticket_attrs(%{title: "New feature"})
      assert {:ok, ticket} = Tickets.create_ticket(attrs)
      assert ticket.title == "New feature"
      assert ticket.status == :backlog
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
      assert_raise Ecto.NoResultsError, fn ->
        Tickets.get_ticket!(Ecto.UUID.generate())
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

  describe "delete_ticket/1" do
    test "deletes the ticket" do
      ticket = insert_ticket!()
      assert {:ok, _} = Tickets.delete_ticket(ticket)

      assert_raise Ecto.NoResultsError, fn ->
        Tickets.get_ticket!(ticket.id)
      end
    end
  end
end
