defmodule AlgedoniaWeb.DaemonChannel do
  @moduledoc """
  Channel for daemon communication. Handles join, heartbeat, and disconnect.
  """
  use Phoenix.Channel

  alias Algedonia.Daemons
  alias Algedonia.Orchestrator
  alias Algedonia.Terminals

  intercept ["start_loop", "stop_loop", "stdin_input"]

  @impl true
  def join("daemon:" <> daemon_id, payload, socket) do
    if daemon_id == socket.assigns.daemon_id do
      name = socket.assigns.daemon_name
      display_name = Map.get(payload, "display_name")

      case Daemons.register_daemon(%{name: name, display_name: display_name}) do
        {:ok, daemon} ->
          socket = assign(socket, :daemon_db_id, daemon.id)
          {:ok, %{status: "ok"}, socket}

        {:error, changeset} ->
          {:error, %{reason: "registration_failed", errors: inspect(changeset.errors)}}
      end
    else
      {:error, %{reason: "unauthorized"}}
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
        {:noreply, socket}

      :error ->
        {:reply, {:error, %{reason: "invalid_base64"}}, socket}
    end
  end

  def handle_in("loop_result", %{"loop_id" => loop_id} = payload, socket) do
    Orchestrator.handle_loop_result(loop_id, payload)
    {:noreply, socket}
  end

  def handle_in("error", %{"loop_id" => loop_id} = payload, socket) do
    Orchestrator.handle_loop_error(loop_id, payload)
    {:noreply, socket}
  end

  def handle_in("loop_exited", %{"loop_id" => loop_id, "exit_code" => exit_code}, socket) do
    Terminals.terminal_ended(loop_id)

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
end
