defmodule AlgedoniaWeb.MonitorLive.Index do
  @moduledoc """
  LiveView for monitoring daemon health and status.
  """
  use AlgedoniaWeb, :live_view

  alias Algedonia.Daemons

  import AlgedoniaWeb.PresenceComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Daemons.subscribe()

    daemons = Daemons.list_daemons()

    {:ok, stream(socket, :daemons, daemons)}
  end

  @impl true
  def handle_info({:daemon_status_changed, daemon}, socket) do
    {:noreply, stream_insert(socket, :daemons, daemon)}
  end

  def handle_info({:daemon_heartbeat, daemon}, socket) do
    {:noreply, stream_insert(socket, :daemons, daemon)}
  end

  defp status_color(:online), do: "bg-green-500"
  defp status_color(:unhealthy), do: "bg-yellow-500"
  defp status_color(:offline), do: "bg-gray-400"
  defp status_color(_), do: "bg-gray-400"

  defp relative_time(nil), do: "never"

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end
end
