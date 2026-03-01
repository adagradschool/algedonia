defmodule AlgedoniaWeb.DaemonChannel do
  @moduledoc """
  Channel for daemon communication. Handles join, heartbeat, and disconnect.
  """
  use Phoenix.Channel

  alias Algedonia.Daemons
  alias Algedonia.{DecomposeOrchestrator, HookExecutor, Loops, TaskLoopOrchestrator}
  alias Algedonia.Terminals
  alias Algedonia.Workspaces

  intercept ["start_loop", "stop_loop", "stdin_input", "get_diff"]

  @impl true
  def join("daemon:" <> daemon_id, payload, socket) do
    if daemon_id == socket.assigns.daemon_id do
      register_and_reply(payload, socket)
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  defp register_and_reply(payload, socket) do
    name = socket.assigns.daemon_name
    display_name = Map.get(payload, "display_name")

    case Daemons.register_daemon(%{name: name, display_name: display_name}) do
      {:ok, daemon} ->
        socket = assign(socket, :daemon_db_id, daemon.id)
        reply = workspace_reply(Map.get(payload, "workspace_slug"))
        {:ok, Map.put(reply, :status, "ok"), socket}

      {:error, changeset} ->
        {:error, %{reason: "registration_failed", errors: inspect(changeset.errors)}}
    end
  end

  defp workspace_reply(nil), do: %{}
  defp workspace_reply(""), do: %{}

  defp workspace_reply(slug) do
    case Workspaces.get_workspace_by_slug(slug) do
      nil ->
        %{}

      workspace ->
        base = %{workspace_slug: workspace.slug}

        if workspace.github_repo_url do
          Map.put(base, :github_repo_url, workspace.github_repo_url)
        else
          base
        end
    end
  end

  @impl true
  def handle_in("heartbeat", payload, socket) do
    daemon = Daemons.get_daemon!(socket.assigns.daemon_db_id)

    attrs = %{
      capacity: Map.get(payload, "capacity", daemon.capacity),
      running_loops: Map.get(payload, "running_loops", daemon.running_loops)
    }

    case Daemons.update_heartbeat(daemon, attrs) do
      {:ok, _daemon} ->
        {:reply, :ok, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "update_failed"}}, socket}
    end
  end

  def handle_in("terminal_output", %{"loop_id" => loop_id, "data" => data}, socket) do
    case Base.decode64(data) do
      {:ok, decoded} ->
        Terminals.append(loop_id, decoded)
        maybe_append_step_output(loop_id, decoded)
        {:noreply, socket}

      :error ->
        {:reply, {:error, %{reason: "invalid_base64"}}, socket}
    end
  end

  def handle_in("loop_result", %{"loop_id" => loop_id} = payload, socket) do
    DecomposeOrchestrator.handle_loop_result(loop_id, payload)
    {:noreply, socket}
  end

  def handle_in("attempt_complete", %{"loop_id" => loop_id} = payload, socket) do
    if uuid_string?(loop_id) do
      case Loops.get_loop(loop_id) do
        %{role: :task} ->
          TaskLoopOrchestrator.handle_attempt_complete(loop_id, payload,
            daemon_name: socket.assigns.daemon_name
          )

        %{role: :hook} ->
          HookExecutor.handle_attempt_complete(loop_id, payload,
            daemon_name: socket.assigns.daemon_name
          )

        _ ->
          TaskLoopOrchestrator.handle_attempt_complete(loop_id, payload,
            daemon_name: socket.assigns.daemon_name
          )
      end
    else
      TaskLoopOrchestrator.handle_attempt_complete(loop_id, payload,
        daemon_name: socket.assigns.daemon_name
      )
    end

    {:noreply, socket}
  end

  def handle_in("error", %{"loop_id" => loop_id} = payload, socket) do
    if uuid_string?(loop_id) do
      case Loops.get_loop(loop_id) do
        %{role: :task} ->
          TaskLoopOrchestrator.handle_attempt_error(loop_id, payload,
            daemon_name: socket.assigns.daemon_name
          )

        %{role: :hook} ->
          HookExecutor.handle_attempt_error(loop_id, payload,
            daemon_name: socket.assigns.daemon_name
          )

        _ ->
          DecomposeOrchestrator.handle_loop_error(loop_id, payload)
      end
    else
      DecomposeOrchestrator.handle_loop_error(loop_id, payload)
    end

    {:noreply, socket}
  end

  def handle_in("repo_clone_status", payload, socket) do
    Daemons.set_repo_status(socket.assigns.daemon_name, payload)
    {:noreply, socket}
  end

  def handle_in("diff_result", %{"loop_id" => loop_id} = payload, socket) do
    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      "loop:#{loop_id}",
      {:diff_result, Map.get(payload, "diff", ""), Map.get(payload, "error")}
    )

    {:noreply, socket}
  end

  def handle_in("loop_exited", %{"loop_id" => loop_id, "exit_code" => exit_code}, socket) do
    Terminals.terminal_ended(loop_id)
    maybe_end_step_terminal(loop_id, exit_code)

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      "terminal:#{loop_id}",
      {:terminal_ended, loop_id, exit_code}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_out(event, payload, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  @doc """
  Pushes a start_loop command to the daemon connected on the given topic.
  """
  def push_start_loop(daemon_name, loop_id, opts \\ %{}) do
    payload = Map.merge(%{"loop_id" => loop_id}, opts)
    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "start_loop", payload)
  end

  @doc """
  Pushes a stop_loop command to the daemon connected on the given topic.
  """
  def push_stop_loop(daemon_name, loop_id, reason \\ "user requested stop") do
    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "stop_loop", %{
      "loop_id" => loop_id,
      "reason" => reason
    })
  end

  @doc """
  Pushes a get_diff command to the daemon to fetch the current git diff for a loop.
  """
  def push_get_diff(daemon_name, loop_id) do
    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "get_diff", %{
      "loop_id" => loop_id
    })
  end

  @doc """
  Pushes stdin_input to the daemon connected on the given topic.
  Data is base64-encoded and forwarded as-is to the daemon for decoding.
  """
  def push_stdin_input(daemon_name, loop_id, data) do
    AlgedoniaWeb.Endpoint.broadcast("daemon:#{daemon_name}", "stdin_input", %{
      "loop_id" => loop_id,
      "data" => data
    })
  end

  @impl true
  def terminate(_reason, socket) do
    if db_id = socket.assigns[:daemon_db_id] do
      daemon = Daemons.get_daemon!(db_id)
      Daemons.mark_unhealthy(daemon)
    end

    :ok
  end

  defp maybe_append_step_output(loop_id, decoded) do
    case TaskLoopOrchestrator.current_step_terminal_id(loop_id) do
      step_id when is_binary(step_id) -> Terminals.append(step_id, decoded)
      _ -> :ok
    end
  end

  defp maybe_end_step_terminal(loop_id, exit_code) do
    case TaskLoopOrchestrator.latest_step_terminal_id(loop_id) do
      step_id when is_binary(step_id) ->
        Terminals.terminal_ended(step_id)

        Phoenix.PubSub.broadcast(
          Algedonia.PubSub,
          "terminal:#{step_id}",
          {:terminal_ended, step_id, exit_code}
        )

      _ ->
        :ok
    end
  end

  defp uuid_string?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp uuid_string?(_), do: false
end
