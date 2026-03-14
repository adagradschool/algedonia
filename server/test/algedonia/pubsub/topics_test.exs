defmodule Algedonia.PubSub.TopicsTest do
  use ExUnit.Case, async: true

  alias Algedonia.PubSub.Topics

  test "builds all workspace-scoped topics" do
    workspace_id = "ws-123"
    ticket_id = "ticket-123"
    loop_id = "loop-123"

    assert Topics.tickets(workspace_id) == "workspace:ws-123:tickets"
    assert Topics.ticket(workspace_id, ticket_id) == "workspace:ws-123:ticket:ticket-123"

    assert Topics.ticket_manual_run(workspace_id, ticket_id) ==
             "workspace:ws-123:ticket_manual_run:ticket-123"

    assert Topics.ticket_loops(workspace_id, ticket_id) ==
             "workspace:ws-123:ticket_loops:ticket-123"

    assert Topics.loop(workspace_id, loop_id) == "workspace:ws-123:loop:loop-123"
    assert Topics.terminal(workspace_id, loop_id) == "workspace:ws-123:terminal:loop-123"
    assert Topics.monitor(workspace_id) == "workspace:ws-123:monitor"
    assert Topics.queue(workspace_id) == "workspace:ws-123:queue"
  end

  test "workspace topics are isolated" do
    workspace_a = Ecto.UUID.generate()
    workspace_b = Ecto.UUID.generate()

    Phoenix.PubSub.subscribe(Algedonia.PubSub, Topics.tickets(workspace_a))

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.tickets(workspace_b),
      {:ticket_created, %{}}
    )

    refute_receive {:ticket_created, %{}}, 100
  end
end
