defmodule Algedonia.PubSub.Topics do
  @moduledoc """
  Canonical topic names for workspace-scoped PubSub channels.
  """

  @type id :: String.t()

  @spec tickets(id()) :: String.t()
  def tickets(workspace_id), do: workspace_prefix(workspace_id) <> "tickets"

  @spec ticket(id(), id()) :: String.t()
  def ticket(workspace_id, ticket_id),
    do: workspace_prefix(workspace_id) <> "ticket:#{ticket_id}"

  @spec ticket_loops(id(), id()) :: String.t()
  def ticket_loops(workspace_id, ticket_id),
    do: workspace_prefix(workspace_id) <> "ticket_loops:#{ticket_id}"

  @spec loop(id(), id()) :: String.t()
  def loop(workspace_id, loop_id), do: workspace_prefix(workspace_id) <> "loop:#{loop_id}"

  @spec terminal(id(), id()) :: String.t()
  def terminal(workspace_id, loop_id),
    do: workspace_prefix(workspace_id) <> "terminal:#{loop_id}"

  @spec monitor(id()) :: String.t()
  def monitor(workspace_id), do: workspace_prefix(workspace_id) <> "monitor"

  @spec queue(id()) :: String.t()
  def queue(workspace_id), do: workspace_prefix(workspace_id) <> "queue"

  defp workspace_prefix(workspace_id), do: "workspace:#{workspace_id}:"
end
