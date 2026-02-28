defmodule Algedonia.Daemons do
  @moduledoc """
  Context for daemon registration and health tracking.
  """
  import Ecto.Query, only: [from: 2]
  alias Algedonia.Daemons.DaemonRegistration
  alias Algedonia.Repo

  @topic "monitor"
  @repo_status_table :daemon_repo_status

  def list_daemons do
    Repo.all(DaemonRegistration)
  end

  def get_daemon!(id) do
    Repo.get!(DaemonRegistration, id)
  end

  def get_daemon(id) do
    Repo.get(DaemonRegistration, id)
  end

  def get_daemon_by_name(name) do
    Repo.get_by(DaemonRegistration, name: name)
  end

  @doc """
  Returns the first online daemon, or `{:error, :no_online_daemon}`.
  """
  @spec find_online() :: {:ok, DaemonRegistration.t()} | {:error, :no_online_daemon}
  def find_online do
    online_daemon =
      from(d in DaemonRegistration,
        where: d.status == :online,
        order_by: [desc: d.last_heartbeat_at, desc: d.connected_at],
        limit: 1
      )
      |> Repo.one()

    case online_daemon do
      nil -> {:error, :no_online_daemon}
      daemon -> {:ok, daemon}
    end
  end

  def register_daemon(attrs) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name")
    now = DateTime.utc_now()

    case get_daemon_by_name(name) do
      nil ->
        %DaemonRegistration{}
        |> DaemonRegistration.changeset(
          Map.merge(attrs, %{status: :online, connected_at: now, last_heartbeat_at: now})
        )
        |> Repo.insert()

      existing ->
        existing
        |> DaemonRegistration.changeset(
          Map.merge(attrs, %{status: :online, connected_at: now, last_heartbeat_at: now})
        )
        |> Repo.update()
    end
    |> tap(fn
      {:ok, daemon} -> broadcast({:daemon_status_changed, daemon})
      _ -> :ok
    end)
  end

  def update_heartbeat(daemon, attrs) do
    daemon
    |> DaemonRegistration.changeset(Map.merge(attrs, %{last_heartbeat_at: DateTime.utc_now()}))
    |> Repo.update()
    |> tap(fn
      {:ok, daemon} -> broadcast({:daemon_heartbeat, daemon})
      _ -> :ok
    end)
  end

  def mark_unhealthy(daemon) do
    daemon
    |> DaemonRegistration.changeset(%{status: :unhealthy})
    |> Repo.update()
    |> tap(fn
      {:ok, daemon} -> broadcast({:daemon_status_changed, daemon})
      _ -> :ok
    end)
  end

  def mark_offline(daemon) do
    daemon
    |> DaemonRegistration.changeset(%{status: :offline, running_loops: 0})
    |> Repo.update()
    |> tap(fn
      {:ok, daemon} -> broadcast({:daemon_status_changed, daemon})
      _ -> :ok
    end)
  end

  @doc """
  Stores the repo clone status for a daemon.
  """
  @spec set_repo_status(binary(), map()) :: :ok
  def set_repo_status(daemon_name, status_payload) do
    ensure_repo_status_table()
    :ets.insert(@repo_status_table, {daemon_name, status_payload})
    broadcast({:repo_clone_status, daemon_name, status_payload})
    :ok
  end

  @doc """
  Returns the repo clone status for a daemon, or nil.
  """
  @spec get_repo_status(binary()) :: map() | nil
  def get_repo_status(daemon_name) do
    ensure_repo_status_table()

    case :ets.lookup(@repo_status_table, daemon_name) do
      [{^daemon_name, status}] -> status
      [] -> nil
    end
  end

  @doc """
  Returns true if the daemon's repo is ready or not required.
  """
  @spec repo_ready?(binary()) :: boolean()
  def repo_ready?(daemon_name) do
    case get_repo_status(daemon_name) do
      %{"status" => "ready"} -> true
      %{"status" => "not_configured"} -> true
      _ -> false
    end
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, @topic)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Algedonia.PubSub, @topic, message)
  end

  defp ensure_repo_status_table do
    if :ets.whereis(@repo_status_table) == :undefined do
      :ets.new(@repo_status_table, [:set, :public, :named_table])
    end

    :ok
  end
end
