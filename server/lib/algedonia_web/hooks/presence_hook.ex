defmodule AlgedoniaWeb.PresenceHook do
  @moduledoc """
  LiveView on_mount hook that tracks user presence per page.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  alias Algedonia.Presence

  def on_mount(:default, _params, session, socket) do
    display_name = session["display_name"] || "Anonymous"
    topic = topic_for(socket.view)

    socket =
      socket
      |> assign(:display_name, display_name)
      |> assign(:presence_topic, topic)
      |> assign(:presences, [])

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

  defp topic_for(AlgedoniaWeb.TicketLive.Index), do: "presence:tickets"
  defp topic_for(AlgedoniaWeb.MonitorLive.Index), do: "presence:monitor"
  defp topic_for(view), do: "presence:#{inspect(view)}"
end
