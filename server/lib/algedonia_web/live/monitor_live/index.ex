defmodule AlgedoniaWeb.MonitorLive.Index do
  @moduledoc """
  LiveView for monitoring daemon health and status.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  alias Algedonia.Daemons

  import AlgedoniaWeb.PresenceComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Daemons.subscribe()

    daemons = Daemons.list_daemons()

    {:ok,
     socket
     |> assign(:daemon_count, length(daemons))
     |> stream(:daemons, daemons)}
  end

  @impl true
  def handle_info({:daemon_status_changed, daemon}, socket) do
    {:noreply,
     socket
     |> assign(:daemon_count, Daemons.list_daemons() |> length())
     |> stream_insert(:daemons, daemon)}
  end

  def handle_info({:daemon_heartbeat, daemon}, socket) do
    {:noreply,
     socket
     |> assign(:daemon_count, Daemons.list_daemons() |> length())
     |> stream_insert(:daemons, daemon)}
  end

  def handle_info({:repo_clone_status, _daemon_id, _status}, socket) do
    {:noreply, socket}
  end

  defp status_color(:online), do: "bg-status-green"
  defp status_color(:unhealthy), do: "bg-status-yellow"
  defp status_color(:offline), do: "bg-fg-muted"
  defp status_color(_), do: "bg-fg-muted"

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
