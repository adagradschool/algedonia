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
      assert ticket.coding_agent == :claude_code
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
