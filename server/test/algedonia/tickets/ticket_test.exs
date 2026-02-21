defmodule Algedonia.Tickets.TicketTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Tickets.Ticket

  describe "changeset/2" do
    test "valid attrs produce valid changeset" do
      attrs = %{title: "Fix bug", type: :bug, priority: 2}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      assert changeset.valid?
    end

    test "missing title is invalid" do
      attrs = %{type: :feature, priority: 3}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing type is invalid" do
      attrs = %{title: "Something", priority: 3}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid status rejected" do
      attrs = %{title: "Test", type: :feature, priority: 3, status: :invalid}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{status: [_]} = errors_on(changeset)
    end

    test "invalid priority 0 rejected" do
      attrs = %{title: "Test", type: :feature, priority: 0}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{priority: [_]} = errors_on(changeset)
    end

    test "invalid priority 6 rejected" do
      attrs = %{title: "Test", type: :feature, priority: 6}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{priority: [_]} = errors_on(changeset)
    end

    test "invalid type rejected" do
      attrs = %{title: "Test", type: :invalid, priority: 3}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{type: [_]} = errors_on(changeset)
    end

    test "default status is backlog" do
      attrs = %{title: "Test", type: :feature, priority: 3}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == :backlog
    end
  end
end
