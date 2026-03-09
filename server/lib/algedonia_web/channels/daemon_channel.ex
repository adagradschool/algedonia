defmodule AlgedoniaWeb.DaemonChannel do
  @moduledoc """
  Channel for daemon communication. Handles join, heartbeat, and disconnect.
  """
  use Phoenix.Channel

  alias Algedonia.{
    Accounts,
    Daemons,
    HookExecutor,
    Loops,
    TaskLoopOrchestrator,
    TenantScope,
    Workspaces
  }

  alias Algedonia.PubSub.Topics
  alias Algedonia.Terminals

  intercept [
    "start_loop",
    "stop_loop",
    "stdin_input",
    "get_diff",
    "cleanup_worktree",
    "open_editor"
  ]

  @impl true
  @spec join(binary(), map(), Phoenix.Socket.t()) ::
          {:ok, map(), Phoenix.Socket.t()} | {:error, map()}
  def join("daemon:" <> daemon_id, payload, socket) do
    if daemon_id == socket.assigns.daemon_id do
      register_and_reply(payload, socket)
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  defp register_and_reply(payload, socket) do
    user_id = socket.assigns.user_id
    name = socket.assigns.daemon_name
    display_name = Map.get(payload, "display_name")
    available_agents = string_list(Map.get(payload, "available_agents"))
    bare_repos = string_list(Map.get(payload, "bare_repos"))
    terminal_ws_url = Map.get(payload, "terminal_ws_url")

    case Daemons.register_daemon(%{
           name: name,
           display_name: display_name,
           user_id: user_id,
           available_agents: available_agents,
           bare_repos: bare_repos,
           terminal_ws_url: terminal_ws_url
         }) do
      {:ok, daemon} ->
        socket =
          socket
          |> assign(:daemon_db_id, daemon.id)
          |> assign(:workspace_slugs, workspace_slugs_for_user(user_id))

        workspaces = workspaces_for_user(socket.assigns[:user_id])
        {:ok, %{status: "ok", workspaces: workspaces}, socket}

      {:error, :name_taken} ->
        {:error, %{reason: "unauthorized"}}

      {:error, changeset} ->
        {:error, %{reason: "registration_failed", errors: inspect(changeset.errors)}}
    end
  end

  defp workspaces_for_user(nil), do: []

  defp workspaces_for_user(user_id) do
    user_id
    |> Accounts.list_workspaces_for_user()
    |> Enum.map(fn ws ->
      base = %{slug: ws.slug}
      if ws.github_repo_url, do: Map.put(base, :github_repo_url, ws.github_repo_url), else: base
    end)
  end

  @impl true
  @spec handle_in(binary(), map(), Phoenix.Socket.t()) ::
          {:noreply, Phoenix.Socket.t()} | {:reply, :ok | {:error, map()}, Phoenix.Socket.t()}
  def handle_in("heartbeat", payload, socket) do
    daemon = Daemons.get_daemon!(socket.assigns.daemon_db_id)

    attrs = %{
      capacity: Map.get(payload, "capacity", daemon.capacity),
      running_loops: Map.get(payload, "running_loops", daemon.running_loops),
      available_agents:
        string_list(Map.get(payload, "available_agents", daemon.available_agents)),
      bare_repos: string_list(Map.get(payload, "bare_repos", daemon.bare_repos))
    }

    case Daemons.update_heartbeat(daemon, attrs) do
      {:ok, updated} ->
        # Reconcile: stop orphan loops the daemon is running that the server doesn't expect
        case Map.get(payload, "running_loop_ids") do
          ids when is_list(ids) ->
            Daemons.reconcile_running_loops(updated, ids)

          _ ->
            :ok
        end

        workspaces = workspaces_for_user(socket.assigns[:user_id])
        push(socket, "workspaces_sync", %{workspaces: workspaces})

        socket = assign(socket, :workspace_slugs, Enum.map(workspaces, & &1.slug))

        {:reply, :ok, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "update_failed"}}, socket}
    end
  end

  def handle_in(
        "terminal_output",
        %{"loop_id" => loop_id, "data" => data, "workspace_slug" => workspace_slug} = payload,
        socket
      ) do
    with true <- uuid_string?(loop_id),
         true <- authorized_workspace_slug?(socket, workspace_slug),
         {:ok, decoded} <- decode_base64(data) do
      workspace_id = workspace_id_from_payload(payload)

      TenantScope.with_workspace(workspace_id, fn ->
        Terminals.append(loop_id, decoded)
        maybe_append_step_output(loop_id, decoded, workspace_id)
      end)

      {:noreply, socket}
    else
      {:error, :invalid_base64} ->
        {:reply, {:error, %{reason: "invalid_base64"}}, socket}

      _ ->
        {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
    end
  end

  def handle_in("terminal_output", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
  end

  def handle_in(
        "attempt_complete",
        %{"loop_id" => loop_id, "role" => role, "workspace_slug" => workspace_slug} = payload,
        socket
      ) do
    with true <- uuid_string?(loop_id),
         true <- authorized_workspace_slug?(socket, workspace_slug),
         %{id: workspace_id} <- Workspaces.get_workspace_by_slug(workspace_slug),
         :ok <-
           route_attempt_complete(
             role,
             loop_id,
             payload,
             socket.assigns.daemon_name,
             workspace_id
           ) do
      {:noreply, socket}
    else
      _ -> {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
    end
  end

  def handle_in("attempt_complete", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
  end

  def handle_in(
        "error",
        %{"loop_id" => loop_id, "role" => role, "workspace_slug" => workspace_slug} = payload,
        socket
      ) do
    with true <- uuid_string?(loop_id),
         true <- authorized_workspace_slug?(socket, workspace_slug),
         %{id: workspace_id} <- Workspaces.get_workspace_by_slug(workspace_slug),
         :ok <-
           route_attempt_error(role, loop_id, payload, socket.assigns.daemon_name, workspace_id) do
      {:noreply, socket}
    else
      _ -> {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
    end
  end

  def handle_in("error", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
  end

  def handle_in("repo_clone_status", payload, socket) do
    workspace_slug = Map.get(payload, "workspace_slug")

    if is_binary(workspace_slug) and workspace_slug != "" and
         authorized_workspace_slug?(socket, workspace_slug) do
      Daemons.set_repo_status(socket.assigns.daemon_name, workspace_slug, payload)
      {:noreply, socket}
    else
      {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
    end
  end

  def handle_in("diff_result", %{"loop_id" => loop_id} = payload, socket) do
    if workspace_id = workspace_id_for_loop(loop_id) do
      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.loop(workspace_id, loop_id),
        {:diff_result, Map.get(payload, "diff", ""), Map.get(payload, "error")}
      )
    end

    {:noreply, socket}
  end

  def handle_in(
        "loop_exited",
        %{"loop_id" => loop_id, "exit_code" => exit_code, "workspace_slug" => workspace_slug} =
          payload,
        socket
      ) do
    with true <- uuid_string?(loop_id),
         true <- authorized_workspace_slug?(socket, workspace_slug) do
      workspace_id = workspace_id_from_payload(payload) || workspace_id_for_loop(loop_id)

      TenantScope.with_workspace(workspace_id, fn ->
        Terminals.terminal_ended(loop_id)
        maybe_end_step_terminal(loop_id, exit_code, workspace_id)
      end)

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.terminal(workspace_id, loop_id),
        {:terminal_ended, loop_id, exit_code}
      )

      {:noreply, socket}
    else
      _ -> {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
    end
  end

  def handle_in("loop_exited", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_workspace_scope"}}, socket}
  end

  @impl true
  def handle_out(event, payload, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  @doc """
  Pushes a start_loop command to the daemon connected on the given topic.
  """
  @spec push_start_loop(String.t(), Algedonia.Types.id(), map()) :: :ok
  def push_start_loop(daemon_name, loop_id, opts \\ %{}) do
    require_non_empty_string!(loop_id, "loop_id", "start_loop")
    require_non_empty_string!(Map.get(opts, "role"), "role", "start_loop")
    require_non_empty_string!(Map.get(opts, "agent_type"), "agent_type", "start_loop")
    require_non_empty_string!(Map.get(opts, "task"), "task", "start_loop")
    require_non_empty_string!(Map.get(opts, "workspace_slug"), "workspace_slug", "start_loop")
    require_non_empty_string!(Map.get(opts, "ticket_id"), "ticket_id", "start_loop")

    payload = Map.merge(%{"loop_id" => loop_id}, opts)
    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "start_loop", payload)
  end

  @doc """
  Pushes a stop_loop command to the daemon connected on the given topic.
  """
  @spec push_stop_loop(String.t(), Algedonia.Types.id(), String.t()) :: :ok
  def push_stop_loop(daemon_name, loop_id, reason \\ "user requested stop") do
    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "stop_loop", %{
      "loop_id" => loop_id,
      "reason" => reason
    })
  end

  @doc """
  Pushes a get_diff command to the daemon to fetch the current git diff for a loop.
  """
  @spec push_get_diff(String.t(), Algedonia.Types.id(), map()) :: :ok
  def push_get_diff(daemon_name, loop_id, opts \\ %{}) do
    require_non_empty_string!(loop_id, "loop_id", "get_diff")
    require_non_empty_string!(Map.get(opts, "workspace_slug"), "workspace_slug", "get_diff")
    require_non_empty_string!(Map.get(opts, "ticket_id"), "ticket_id", "get_diff")

    payload = Map.merge(%{"loop_id" => loop_id}, opts)
    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "get_diff", payload)
  end

  @doc """
  Pushes stdin_input to the daemon connected on the given topic.
  Data is base64-encoded and forwarded as-is to the daemon for decoding.
  """
  @spec push_stdin_input(String.t(), Algedonia.Types.id(), String.t()) :: :ok
  def push_stdin_input(daemon_name, loop_id, data) do
    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "stdin_input", %{
      "loop_id" => loop_id,
      "data" => data
    })
  end

  @doc """
  Pushes a cleanup_worktree command to the daemon to remove a ticket's worktree.
  """
  @spec push_cleanup_worktree(String.t(), Algedonia.Types.id(), String.t()) :: :ok
  def push_cleanup_worktree(daemon_name, ticket_id, workspace_slug) do
    require_non_empty_string!(ticket_id, "ticket_id", "cleanup_worktree")
    require_non_empty_string!(workspace_slug, "workspace_slug", "cleanup_worktree")

    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "cleanup_worktree", %{
      "ticket_id" => ticket_id,
      "workspace_slug" => workspace_slug
    })
  end

  @doc """
  Pushes an open_editor command to the daemon to open either a ticket worktree
  or a specific file path within a workspace.
  """
  @spec push_open_editor(String.t(), Algedonia.Types.id(), String.t()) :: :ok
  def push_open_editor(daemon_name, ticket_id, workspace_slug)
      when is_binary(ticket_id) and is_binary(workspace_slug) do
    push_open_editor(daemon_name, workspace_slug, %{"ticket_id" => ticket_id})
  end

  @spec push_open_editor(String.t(), String.t(), map()) :: :ok
  def push_open_editor(daemon_name, workspace_slug, opts) when is_map(opts) do
    require_non_empty_string!(workspace_slug, "workspace_slug", "open_editor")

    payload =
      opts
      |> open_editor_payload()
      |> Map.put("workspace_slug", workspace_slug)

    if Map.get(payload, "ticket_id") in [nil, ""] and Map.get(payload, "source_path") in [nil, ""] do
      raise ArgumentError, "open_editor requires ticket_id or source_path"
    end

    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "open_editor", payload)
  end

  defp open_editor_payload(opts) do
    opts
    |> Enum.reduce(%{}, fn
      {"ticket_id", value}, acc when is_binary(value) and value != "" ->
        Map.put(acc, "ticket_id", value)

      {:ticket_id, value}, acc when is_binary(value) and value != "" ->
        Map.put(acc, "ticket_id", value)

      {"source_path", value}, acc when is_binary(value) and value != "" ->
        Map.put(acc, "source_path", value)

      {:source_path, value}, acc when is_binary(value) and value != "" ->
        Map.put(acc, "source_path", value)

      _, acc ->
        acc
    end)
  end

  @impl true
  def terminate(_reason, socket) do
    if db_id = socket.assigns[:daemon_db_id] do
      daemon = Daemons.get_daemon!(db_id)
      Daemons.mark_unhealthy(daemon)
    end

    :ok
  end

  defp maybe_append_step_output(loop_id, decoded, workspace_id) do
    case TaskLoopOrchestrator.current_step_terminal_id(loop_id, workspace_id: workspace_id) do
      step_id when is_binary(step_id) -> Terminals.append(step_id, decoded)
      _ -> :ok
    end
  end

  defp maybe_end_step_terminal(loop_id, exit_code, workspace_id) do
    case TaskLoopOrchestrator.latest_step_terminal_id(loop_id, workspace_id: workspace_id) do
      step_id when is_binary(step_id) ->
        Terminals.terminal_ended(step_id)

        Phoenix.PubSub.broadcast(
          Algedonia.PubSub,
          Topics.terminal(workspace_id, step_id),
          {:terminal_ended, step_id, exit_code}
        )

      _ ->
        :ok
    end
  end

  defp route_attempt_complete(role, loop_id, payload, daemon_name, workspace_id)
       when role in ["maker", "checker"] do
    TaskLoopOrchestrator.handle_attempt_complete(loop_id, payload,
      daemon_name: daemon_name,
      workspace_id: workspace_id
    )

    :ok
  end

  defp route_attempt_complete("review", loop_id, payload, daemon_name, workspace_id) do
    Algedonia.ReviewLoop.handle_attempt_complete(loop_id, payload,
      daemon_name: daemon_name,
      workspace_id: workspace_id
    )

    :ok
  end

  defp route_attempt_complete("hook", loop_id, payload, _daemon_name, workspace_id) do
    HookExecutor.handle_attempt_complete(loop_id, payload, workspace_id: workspace_id)

    :ok
  end

  defp route_attempt_complete("planning", loop_id, payload, _daemon_name, workspace_id) do
    TenantScope.with_workspace(workspace_id, fn ->
      complete_planning_loop(loop_id, payload)
    end)

    :ok
  end

  defp route_attempt_complete(_, _, _, _, _), do: {:error, :invalid_role}

  defp route_attempt_error(role, loop_id, payload, daemon_name, workspace_id)
       when role in ["maker", "checker"] do
    TaskLoopOrchestrator.handle_attempt_error(loop_id, payload,
      daemon_name: daemon_name,
      workspace_id: workspace_id
    )

    :ok
  end

  defp route_attempt_error("review", loop_id, payload, daemon_name, workspace_id) do
    Algedonia.ReviewLoop.handle_attempt_error(loop_id, payload,
      daemon_name: daemon_name,
      workspace_id: workspace_id
    )

    :ok
  end

  defp route_attempt_error("hook", loop_id, payload, _daemon_name, workspace_id) do
    HookExecutor.handle_attempt_error(loop_id, payload, workspace_id: workspace_id)

    :ok
  end

  defp route_attempt_error("planning", loop_id, payload, _daemon_name, workspace_id) do
    TenantScope.with_workspace(workspace_id, fn ->
      complete_planning_loop(loop_id, payload)
    end)

    :ok
  end

  defp route_attempt_error(_, _, _, _, _), do: {:error, :invalid_role}

  defp complete_planning_loop(loop_id, payload) do
    case Loops.get_loop(loop_id) do
      %{role: :planning} = loop ->
        ec = Map.get(payload, "exit_code", 0)
        sid = Map.get(payload, "session_id")

        Loops.complete_last_running(loop.id, "planning", loop.current_attempt, %{
          session_id: sid,
          exit_code: ec,
          status: "completed"
        })

        _ = Loops.update_loop_status(loop, :passed)
        :ok

      _ ->
        :ok
    end
  end

  defp workspace_id_from_payload(%{"workspace_slug" => workspace_slug})
       when is_binary(workspace_slug) do
    case Workspaces.get_workspace_by_slug(workspace_slug) do
      %{id: workspace_id} -> workspace_id
      _ -> nil
    end
  end

  defp workspace_id_from_payload(_), do: nil

  defp workspace_id_for_loop(loop_id) do
    case Loops.get_loop(loop_id) do
      %{workspace_id: workspace_id} -> workspace_id
      _ -> nil
    end
  end

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp uuid_string?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp uuid_string?(_), do: false

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp string_list(_), do: []

  defp workspace_slugs_for_user(nil), do: []

  defp workspace_slugs_for_user(user_id),
    do: user_id |> workspaces_for_user() |> Enum.map(& &1.slug)

  defp authorized_workspace_slug?(socket, workspace_slug) do
    cached_slugs = socket.assigns[:workspace_slugs] || []
    fresh_slugs = workspace_slugs_for_user(socket.assigns[:user_id])

    workspace_slug in cached_slugs or workspace_slug in fresh_slugs
  end

  defp require_non_empty_string!(value, _field, _event)
       when is_binary(value) and value != "",
       do: value

  defp require_non_empty_string!(_value, field, event) do
    raise ArgumentError, "#{event} requires non-empty #{field}"
  end
end
