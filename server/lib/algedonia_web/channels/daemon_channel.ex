defmodule AlgedoniaWeb.DaemonChannel do
  @moduledoc """
  Channel for daemon communication. Handles join, heartbeat, and disconnect.
  """
  use Phoenix.Channel

  alias Algedonia.Daemons

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

  @impl true
  def terminate(_reason, socket) do
    if db_id = socket.assigns[:daemon_db_id] do
      daemon = Daemons.get_daemon!(db_id)
      Daemons.mark_unhealthy(daemon)
    end

    :ok
  end
end
