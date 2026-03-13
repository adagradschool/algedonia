defmodule AlgedoniaWeb.PresenceHook do
  @moduledoc """
  LiveView on_mount hook that tracks user presence per page.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  alias Algedonia.Accounts
  alias Algedonia.Accounts.User
  alias Algedonia.Daemons
  alias Algedonia.Presence
  alias Algedonia.Workspaces
  alias AlgedoniaWeb.Helpers

  def on_mount(:default, params, session, socket) do
    workspace_slug = params["workspace"]
    workspace = resolve_workspace(workspace_slug, session["current_workspace_id"])

    {current_user, user_workspaces} =
      case session["user_id"] do
        nil ->
          {nil, []}

        id ->
          user = Accounts.get_user(id)
          workspaces = if user, do: Accounts.list_workspaces_for_user(id), else: []
          {user, workspaces}
      end

    display_name = display_name_for(current_user, session["display_name"])

    topic = topic_for(socket.view, workspace_slug)

    if workspace, do: Algedonia.TenantScope.put_workspace(workspace.id)

    daemon_statuses = daemon_statuses_for(workspace)
    workspace_daemon_status = Helpers.aggregate_daemon_status(Map.values(daemon_statuses))

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
      |> assign(:user_workspaces, user_workspaces)
      |> assign(:workspace_daemon_statuses, daemon_statuses)
      |> assign(:workspace_daemon_status, workspace_daemon_status)
      |> assign(:forward_daemon_events?, socket.view == AlgedoniaWeb.MonitorLive.Index)
      |> assign(:github_token, session["github_token"])
      |> assign(:show_new_workspace_modal, false)
      |> attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
        {:cont, assign(socket, :current_path, URI.parse(uri).path)}
      end)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Algedonia.PubSub, topic)

      if workspace && socket.view != AlgedoniaWeb.MonitorLive.Index do
        Daemons.subscribe(workspace.id)
      end

      Presence.track(self(), topic, display_name, %{
        display_name: display_name,
        joined_at: System.system_time(:second)
      })

      presences = list_presences(topic)

      socket =
        socket
        |> assign(:presences, presences)
        |> attach_hook(:presence_diff, :handle_info, &handle_presence_diff/2)
        |> attach_hook(:workspace_daemon_badge, :handle_info, &handle_daemon_update/2)

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

  defp handle_daemon_update({event, daemon}, socket)
       when event in [:daemon_status_changed, :daemon_heartbeat] do
    statuses =
      socket.assigns.workspace_daemon_statuses
      |> Map.put(daemon.id, daemon.status)

    socket =
      socket
      |> assign(:workspace_daemon_statuses, statuses)
      |> assign(:workspace_daemon_status, Helpers.aggregate_daemon_status(Map.values(statuses)))

    if socket.assigns.forward_daemon_events?, do: {:cont, socket}, else: {:halt, socket}
  end

  defp handle_daemon_update({:repo_clone_status, _daemon_name, _workspace_slug, _payload}, socket) do
    if socket.assigns.forward_daemon_events?, do: {:cont, socket}, else: {:halt, socket}
  end

  defp handle_daemon_update(_msg, socket), do: {:cont, socket}

  defp list_presences(topic) do
    topic
    |> Presence.list()
    |> Enum.map(fn {name, %{metas: [meta | _]}} ->
      Map.put(meta, :display_name, name)
    end)
  end

  defp daemon_statuses_for(nil), do: %{}

  defp daemon_statuses_for(workspace) do
    workspace.id
    |> Daemons.list_daemons()
    |> Map.new(fn daemon -> {daemon.id, daemon.status} end)
  end

  defp topic_for(view, workspace_slug) do
    base =
      case view do
        AlgedoniaWeb.TicketLive.Index -> "presence:tickets"
        AlgedoniaWeb.MonitorLive.Index -> "presence:monitor"
        AlgedoniaWeb.SkillsLive.Index -> "presence:skills"
        _ -> "presence:#{inspect(view)}"
      end

    if workspace_slug, do: "#{base}:#{workspace_slug}", else: base
  end

  defp nav_section_for(AlgedoniaWeb.TicketLive.Index), do: :issues
  defp nav_section_for(AlgedoniaWeb.MonitorLive.Index), do: :monitor
  defp nav_section_for(AlgedoniaWeb.SkillsLive.Index), do: :skills
  defp nav_section_for(AlgedoniaWeb.LoopLive.Show), do: :issues
  defp nav_section_for(AlgedoniaWeb.SettingsLive.Index), do: :settings
  defp nav_section_for(_), do: nil

  defp display_name_for(%User{} = user, fallback) do
    fallback || user.name || user.github_username || "Anonymous"
  end

  defp display_name_for(nil, fallback), do: fallback || "Anonymous"

  defp resolve_workspace(nil, workspace_id) do
    if workspace_id, do: Workspaces.get_workspace!(workspace_id), else: nil
  end

  defp resolve_workspace(workspace_slug, _workspace_id) do
    Workspaces.get_workspace_by_slug(workspace_slug)
  end
end
