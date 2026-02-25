defmodule Algedonia.Tickets.TicketTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Tickets.Ticket
  import Algedonia.Factory

  describe "changeset/2" do
    test "valid attrs produce valid changeset" do
      workspace = default_workspace!()
      attrs = %{title: "Fix bug", type: :bug, priority: 2, workspace_id: workspace.id}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      assert changeset.valid?
    end

    test "missing title is invalid" do
      workspace = default_workspace!()
      attrs = %{type: :feature, priority: 3, workspace_id: workspace.id}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing type is invalid" do
      workspace = default_workspace!()
      attrs = %{title: "Something", priority: 3, workspace_id: workspace.id}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid status rejected" do
      workspace = default_workspace!()

      attrs = %{
        title: "Test",
        type: :feature,
        priority: 3,
        status: :invalid,
        workspace_id: workspace.id
      }

      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{status: [_]} = errors_on(changeset)
    end

    test "invalid priority 0 rejected" do
      workspace = default_workspace!()
      attrs = %{title: "Test", type: :feature, priority: 0, workspace_id: workspace.id}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{priority: [_]} = errors_on(changeset)
    end

    test "invalid priority 6 rejected" do
      workspace = default_workspace!()
      attrs = %{title: "Test", type: :feature, priority: 6, workspace_id: workspace.id}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{priority: [_]} = errors_on(changeset)
    end

    test "invalid type rejected" do
      workspace = default_workspace!()
      attrs = %{title: "Test", type: :invalid, priority: 3, workspace_id: workspace.id}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{type: [_]} = errors_on(changeset)
    end

    test "default status is backlog" do
      workspace = default_workspace!()
      attrs = %{title: "Test", type: :feature, priority: 3, workspace_id: workspace.id}
      changeset = Ticket.changeset(%Ticket{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == :backlog
    end

    test "default coding_agent follows global config" do
      workspace = default_workspace!()
      attrs = %{title: "Test", type: :feature, priority: 3, workspace_id: workspace.id}
      changeset = Ticket.changeset(%Ticket{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :coding_agent) ==
               Algedonia.Agents.default_coding_agent()
    end

    test "invalid coding_agent rejected" do
      workspace = default_workspace!()

      attrs = %{
        title: "Test",
        type: :feature,
        priority: 3,
        coding_agent: :invalid,
        workspace_id: workspace.id
      }

      changeset = Ticket.changeset(%Ticket{}, attrs)
      refute changeset.valid?
      assert %{coding_agent: [_]} = errors_on(changeset)
    end
  end
end
