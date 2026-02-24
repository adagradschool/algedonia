defmodule AlgedoniaWeb.PresenceHook do
  @moduledoc """
  LiveView on_mount hook that tracks user presence per page.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  alias Algedonia.Accounts
  alias Algedonia.Presence
  alias Algedonia.Workspaces

  def on_mount(:default, params, session, socket) do
    display_name = session["display_name"] || "Anonymous"
    workspace_slug = params["workspace"]

    workspace =
      if id = session["current_workspace_id"] do
        Workspaces.get_workspace!(id)
      else
        nil
      end

    current_user =
      case session["user_id"] do
        nil -> nil
        id -> Accounts.get_user(id)
      end

    topic = topic_for(socket.view, workspace_slug)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:display_name, display_name)
      |> assign(:presence_topic, topic)
      |> assign(:presences, [])
      |> assign(:current_scope, nil)
      |> assign(:nav_section, nav_section_for(socket.view))
      |> assign(:workspace_slug, workspace_slug)
      |> assign(:current_workspace, workspace)
      |> attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
        {:cont, assign(socket, :current_path, URI.parse(uri).path)}
      end)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Algedonia.PubSub, topic)

      Presence.track(self(), topic, display_name, %{
        display_name: display_name,
        joined_at: System.system_time(:second)
      })

      presences = list_presences(topic)

      socket =
        socket
        |> assign(:presences, presences)
        |> attach_hook(:presence_diff, :handle_info, &handle_presence_diff/2)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  defp handle_presence_diff(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    presences = list_presences(socket.assigns.presence_topic)
    {:halt, assign(socket, :presences, presences)}
  end

  defp handle_presence_diff(_msg, socket), do: {:cont, socket}

  defp list_presences(topic) do
    topic
    |> Presence.list()
    |> Enum.map(fn {name, %{metas: [meta | _]}} ->
      Map.put(meta, :display_name, name)
    end)
  end

  defp topic_for(view, workspace_slug) do
    base =
      case view do
        AlgedoniaWeb.TicketLive.Index -> "presence:tickets"
        AlgedoniaWeb.MonitorLive.Index -> "presence:monitor"
        _ -> "presence:#{inspect(view)}"
      end

    if workspace_slug, do: "#{base}:#{workspace_slug}", else: base
  end

  defp nav_section_for(AlgedoniaWeb.TicketLive.Index), do: :issues
  defp nav_section_for(AlgedoniaWeb.MonitorLive.Index), do: :monitor
  defp nav_section_for(AlgedoniaWeb.LoopLive.Show), do: :loops
  defp nav_section_for(AlgedoniaWeb.DagLive.Show), do: :issues
  defp nav_section_for(_), do: nil
end
