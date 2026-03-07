defmodule Algedonia.Daemons do
  @moduledoc """
  Context for daemon registration and health tracking.
  """
  import Ecto.Query, only: [from: 2]
  alias Algedonia.Accounts
  alias Algedonia.Daemons.DaemonRegistration
  alias Algedonia.Loops
  alias Algedonia.PubSub.Topics
  alias Algedonia.Repo
  alias Algedonia.TaskLoopOrchestrator
  alias Algedonia.Workspaces.WorkspaceMembership

  @repo_status_table :daemon_repo_status

  @spec list_daemons() :: [DaemonRegistration.t()]
  def list_daemons do
    Repo.all(DaemonRegistration)
  end

  @spec list_daemons(Algedonia.Types.id()) :: [DaemonRegistration.t()]
  def list_daemons(workspace_id) do
    from(d in DaemonRegistration,
      join: m in WorkspaceMembership,
      on: m.user_id == d.user_id,
      where: m.workspace_id == ^workspace_id,
      distinct: d.id
    )
    |> Repo.all()
  end

  @spec get_daemon!(Algedonia.Types.id()) :: DaemonRegistration.t()
  def get_daemon!(id) do
    Repo.get!(DaemonRegistration, id)
  end

  @spec get_daemon(Algedonia.Types.id()) :: DaemonRegistration.t() | nil
  def get_daemon(id) do
    Repo.get(DaemonRegistration, id)
  end

  @spec get_daemon_by_name(String.t()) :: DaemonRegistration.t() | nil
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

  @spec register_daemon(map()) ::
          {:ok, DaemonRegistration.t()} | {:error, Ecto.Changeset.t() | :name_taken}
  def register_daemon(attrs) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name")
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")
    now = DateTime.utc_now()

    registration_attrs =
      Map.merge(attrs, %{status: :online, connected_at: now, last_heartbeat_at: now})

    case get_daemon_by_name(name) do
      nil ->
        %DaemonRegistration{}
        |> DaemonRegistration.changeset(registration_attrs)
        |> Repo.insert()

      existing when existing.user_id == user_id ->
        existing
        |> DaemonRegistration.changeset(registration_attrs)
        |> Repo.update()

      _existing ->
        {:error, :name_taken}
    end
    |> tap(fn
      {:ok, daemon} ->
        Loops.requeue_running_task_loops_for_daemon(daemon.id)
        broadcast({:daemon_status_changed, daemon}, daemon)

      _ ->
        :ok
    end)
  end

  @spec update_heartbeat(DaemonRegistration.t(), map()) ::
          {:ok, DaemonRegistration.t()} | {:error, Ecto.Changeset.t()}
  def update_heartbeat(daemon, attrs) do
    was_unhealthy = daemon.status == :unhealthy

    updates =
      if daemon.status in [:unhealthy, :offline],
        do: Map.merge(attrs, %{last_heartbeat_at: DateTime.utc_now(), status: :online}),
        else: Map.merge(attrs, %{last_heartbeat_at: DateTime.utc_now()})

    daemon
    |> DaemonRegistration.changeset(updates)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} ->
        broadcast({:daemon_heartbeat, updated}, updated)

        if was_unhealthy do
          broadcast({:daemon_status_changed, updated}, updated)
          redispatch_pending_loops(updated)
        end

      _ ->
        :ok
    end)
  end

  @spec mark_unhealthy(DaemonRegistration.t()) ::
          {:ok, DaemonRegistration.t()} | {:error, Ecto.Changeset.t()}
  def mark_unhealthy(daemon) do
    daemon
    |> DaemonRegistration.changeset(%{status: :unhealthy})
    |> Repo.update()
    |> tap(fn
      {:ok, daemon} ->
        Loops.requeue_running_task_loops_for_daemon(daemon.id)
        broadcast({:daemon_status_changed, daemon}, daemon)

      _ ->
        :ok
    end)
  end

  @spec mark_offline(DaemonRegistration.t()) ::
          {:ok, DaemonRegistration.t()} | {:error, Ecto.Changeset.t()}
  def mark_offline(daemon) do
    daemon
    |> DaemonRegistration.changeset(%{status: :offline, running_loops: 0})
    |> Repo.update()
    |> tap(fn
      {:ok, daemon} ->
        Loops.requeue_running_task_loops_for_daemon(daemon.id)
        broadcast({:daemon_status_changed, daemon}, daemon)

      _ ->
        :ok
    end)
  end

  @doc """
  Stores the repo clone status for a daemon and workspace.
  """
  @spec set_repo_status(String.t(), String.t(), map()) :: :ok
  def set_repo_status(daemon_name, workspace_slug, status_payload) do
    ensure_repo_status_table()
    :ets.insert(@repo_status_table, {{daemon_name, workspace_slug}, status_payload})

    case get_daemon_by_name(daemon_name) do
      nil ->
        :ok

      daemon ->
        broadcast({:repo_clone_status, daemon_name, workspace_slug, status_payload}, daemon)
    end

    :ok
  end

  @doc """
  Returns the repo clone status for a daemon and workspace, or nil.
  """
  @spec get_repo_status(String.t(), String.t()) :: map() | nil
  def get_repo_status(daemon_name, workspace_slug) do
    ensure_repo_status_table()
    key = {daemon_name, workspace_slug}

    case :ets.lookup(@repo_status_table, key) do
      [{^key, status}] -> status
      [] -> nil
    end
  end

  @doc """
  Returns true if the daemon's repo is ready for the given workspace, or not required.
  """
  @spec repo_ready?(String.t(), String.t()) :: boolean()
  def repo_ready?(daemon_name, workspace_slug) do
    case get_repo_status(daemon_name, workspace_slug) do
      %{"status" => "ready"} -> true
      %{"status" => "not_configured"} -> true
      _ -> false
    end
  end

  @doc """
  Re-dispatches pending task loops to a daemon that just came back online.
  """
  @spec redispatch_pending_loops(DaemonRegistration.t()) :: [term()]
  def redispatch_pending_loops(daemon) do
    for loop <- Loops.list_pending_unassigned_task_loops() do
      case TaskLoopOrchestrator.start_task_loop(loop.id, daemon.name,
             workspace_id: loop.workspace_id
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("Failed to redispatch loop #{loop.id}: #{inspect(reason)}")
      end
    end
  end

  @doc """
  Reconciles server state with what the daemon reports it's running.
  Stops orphan loops on the daemon and redispatches missing loops.
  """
  @spec reconcile_running_loops(DaemonRegistration.t(), [Algedonia.Types.id()]) :: :ok
  def reconcile_running_loops(daemon, reported_loop_ids) when is_list(reported_loop_ids) do
    server_running =
      daemon.id
      |> Loops.list_running_loops_for_daemon()
      |> Enum.map(& &1.id)
      |> MapSet.new()

    daemon_running = MapSet.new(reported_loop_ids)

    # Orphans: daemon is running them but server doesn't think so
    orphans = MapSet.difference(daemon_running, server_running)

    for loop_id <- orphans do
      AlgedoniaWeb.DaemonChannel.push_stop_loop(daemon.name, loop_id, "orphan reconciliation")
    end

    :ok
  end

  @spec subscribe(Algedonia.Types.id()) :: :ok | {:error, term()}
  def subscribe(workspace_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, Topics.monitor(workspace_id))
  end

  defp broadcast(message, %{user_id: user_id}) do
    user_id
    |> Accounts.list_workspaces_for_user()
    |> Enum.each(fn workspace ->
      Phoenix.PubSub.broadcast(Algedonia.PubSub, Topics.monitor(workspace.id), message)
    end)

    :ok
  end

  defp broadcast(_message, _daemon), do: :ok

  defp ensure_repo_status_table do
    if :ets.whereis(@repo_status_table) == :undefined do
      :ets.new(@repo_status_table, [:set, :public, :named_table])
    end

    :ok
  end
end
