defmodule Algedonia.Tracker.NoOp do
  @moduledoc """
  No-op tracker adapter. Returns success for all callbacks without side effects.
  """
  @behaviour Algedonia.Tracker

  @impl true
  def create_ticket(_workspace, _attrs), do: {:ok, %{}}

  @impl true
  def update_ticket(_workspace, _ticket_id, _attrs), do: {:ok, %{}}

  @impl true
  def delete_ticket(_workspace, _ticket_id), do: :ok

  @impl true
  def sync_status(_workspace, _ticket_id, _new_status), do: :ok
end
