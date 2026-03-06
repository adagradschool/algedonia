defmodule Algedonia.Loops do
  @moduledoc """
  Context for loop management — CRUD and status updates with PubSub broadcasts.
  """
  import Ecto.Query

  alias Algedonia.Loops.{Loop, LoopStep}
  alias Algedonia.Repo

  @doc """
  Gets a single loop. Raises `Ecto.NoResultsError` if not found.
  """
  @spec get_loop!(binary()) :: Loop.t()
  def get_loop!(id), do: Repo.get!(Loop, id)

  @doc """
  Gets a single loop, returns nil if not found.
  """
  @spec get_loop(binary()) :: Loop.t() | nil
  def get_loop(id), do: Repo.get(Loop, id)

  @doc """
  Gets a loop by URL reference.

  Accepts a UUID or a short ID prefix.
  """
  @spec get_loop_by_ref(binary()) :: Loop.t() | nil
  def get_loop_by_ref(ref) when is_binary(ref) do
    if uuid?(ref) do
      get_loop(ref)
    else
      ref = String.downcase(ref)
      len = String.length(ref)

      from(l in Loop,
        where: fragment("left((?)::text, ?)", l.id, ^len) == ^ref,
        limit: 2
      )
      |> Repo.all()
      |> case do
        [loop] -> loop
        _ -> nil
      end
    end
  end

  @spec get_loop_by_ref!(binary()) :: Loop.t()
  def get_loop_by_ref!(ref) when is_binary(ref) do
    case get_loop_by_ref(ref) do
      nil -> raise Ecto.NoResultsError, queryable: Loop
      loop -> loop
    end
  end

  @doc """
  Gets a loop with ticket preloaded. Raises if not found.
  """
  @spec get_loop_with_ticket!(binary()) :: Loop.t()
  def get_loop_with_ticket!(id) do
    get_loop!(id) |> Repo.preload(:ticket)
  end

  @doc """
  Gets a loop by reference with ticket preloaded. Raises if not found.
  """
  @spec get_loop_with_ticket_by_ref!(binary()) :: Loop.t()
  def get_loop_with_ticket_by_ref!(ref) do
    get_loop_by_ref!(ref) |> Repo.preload(:ticket)
  end

  @doc """
  Creates a loop.
  """
  @spec create_loop(map()) :: {:ok, Loop.t()} | {:error, Ecto.Changeset.t()}
  def create_loop(attrs) do
    %Loop{}
    |> Loop.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a loop's status and broadcasts the change.
  """
  @spec update_loop_status(Loop.t(), atom()) :: {:ok, Loop.t()} | {:error, Ecto.Changeset.t()}
  def update_loop_status(%Loop{} = loop, status) do
    loop
    |> Loop.changeset(%{status: status})
    |> Repo.update()
    |> tap(fn
      {:ok, loop} ->
        loop = Repo.preload(loop, :ticket)
        ticket_id = loop.ticket_id

        Phoenix.PubSub.broadcast(
          Algedonia.PubSub,
          "ticket_loops:#{ticket_id}",
          {:loop_status_changed, loop}
        )

        Phoenix.PubSub.broadcast(
          Algedonia.PubSub,
          "loop:#{loop.id}",
          {:loop_updated, loop}
        )

      _ ->
        :ok
    end)
  end

  @doc """
  Updates a loop with arbitrary attributes.
  """
  @spec update_loop(Loop.t(), map()) :: {:ok, Loop.t()} | {:error, Ecto.Changeset.t()}
  def update_loop(%Loop{} = loop, attrs) do
    loop
    |> Loop.changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, loop} ->
        Phoenix.PubSub.broadcast(
          Algedonia.PubSub,
          "loop:#{loop.id}",
          {:loop_updated, loop}
        )

      _ ->
        :ok
    end)
  end

  @doc """
  Preloads a loop's ticket association.
  """
  @spec preload_ticket(Loop.t()) :: Loop.t()
  def preload_ticket(%Loop{} = loop), do: Repo.preload(loop, :ticket)

  @doc """
  Preloads a loop with its ticket.
  """
  @spec preload_with_ticket(Loop.t()) :: Loop.t()
  def preload_with_ticket(%Loop{} = loop), do: Repo.preload(loop, :ticket)

  @doc """
  Preloads a loop with ticket and workspace.
  """
  @spec preload_with_workspace(Loop.t()) :: Loop.t()
  def preload_with_workspace(%Loop{} = loop), do: Repo.preload(loop, ticket: :workspace)

  @doc """
  Lists hook loops for a ticket, ordered by insertion time.
  """
  @spec list_hook_loops_for_ticket(binary()) :: [Loop.t()]
  def list_hook_loops_for_ticket(ticket_id) do
    Loop
    |> where([l], l.ticket_id == ^ticket_id and l.role == :hook)
    |> order_by([l], desc: l.inserted_at)
    |> Repo.all()
  end

  @doc """
  Requeues running task loops assigned to a daemon.

  This is used when a daemon disconnects so orphaned loops do not remain
  stuck in a running state.
  """
  @spec requeue_running_task_loops_for_daemon(binary()) :: [Loop.t()]
  def requeue_running_task_loops_for_daemon(daemon_id) when is_binary(daemon_id) do
    Loop
    |> where(
      [l],
      l.assigned_daemon_id == ^daemon_id and l.role == :task and
        l.status == :running
    )
    |> Repo.all()
    |> Enum.map(fn loop ->
      {:ok, updated} =
        update_loop(loop, %{
          status: :pending,
          assigned_daemon_id: nil
        })

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        "ticket_loops:#{updated.ticket_id}",
        {:loop_status_changed, updated}
      )

      updated
    end)
  end

  @doc """
  Returns all loops for a ticket, ordered by insertion time.
  """
  @spec list_loops_for_ticket(binary()) :: [Loop.t()]
  def list_loops_for_ticket(ticket_id) do
    Loop
    |> where([l], l.ticket_id == ^ticket_id)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns all task loops for a ticket, ordered by insertion time.
  """
  @spec list_task_loops_for_ticket(binary()) :: [Loop.t()]
  def list_task_loops_for_ticket(ticket_id) do
    Loop
    |> where([l], l.ticket_id == ^ticket_id and l.role == :task)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns the first task-loop ID for each ticket ID.
  """
  @spec first_loop_ids_for_tickets([binary()]) :: %{binary() => binary()}
  def first_loop_ids_for_tickets([]), do: %{}

  def first_loop_ids_for_tickets(ticket_ids) do
    from(l in Loop,
      where: l.role == :task and l.ticket_id in ^ticket_ids,
      distinct: l.ticket_id,
      order_by: [asc: l.ticket_id, asc: l.inserted_at],
      select: {l.ticket_id, l.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns the first inspectable loop ID for each ticket ID.
  """
  @spec first_inspect_loop_ids_for_tickets([binary()]) :: %{binary() => binary()}
  def first_inspect_loop_ids_for_tickets([]), do: %{}

  def first_inspect_loop_ids_for_tickets(ticket_ids) do
    from(l in Loop,
      where: l.ticket_id in ^ticket_ids and l.role != :hook,
      order_by: [
        asc: l.ticket_id,
        asc: fragment("CASE WHEN ? = ? THEN 0 ELSE 1 END", l.role, ^"task"),
        asc: l.inserted_at
      ],
      select: {l.ticket_id, l.id}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {ticket_id, loop_id}, acc ->
      Map.put_new(acc, ticket_id, loop_id)
    end)
  end

  @doc """
  Returns active loop info for the given ticket IDs.
  """
  @spec active_loop_info_for_tickets([binary()]) :: %{
          binary() => %{loop_id: binary(), stage: String.t(), attempt: integer()}
        }
  def active_loop_info_for_tickets([]), do: %{}

  def active_loop_info_for_tickets(ticket_ids) do
    terminal = [:passed, :failed]

    active =
      from(l in Loop,
        where: l.ticket_id in ^ticket_ids and l.role != :hook and l.status not in ^terminal,
        distinct: l.ticket_id,
        order_by: [asc: l.ticket_id, asc: l.inserted_at],
        select: {l.ticket_id, l.id, l.status, l.current_attempt}
      )
      |> Repo.all()
      |> Map.new(fn {tid, lid, _status, attempt} ->
        {tid, %{loop_id: lid, attempt: max(attempt, 1)}}
      end)

    missing = ticket_ids -- Map.keys(active)
    fallback = first_inspect_loop_ids_for_tickets(missing)

    all_info =
      Map.merge(
        active,
        Map.new(fallback, fn {tid, lid} ->
          case get_loop(lid) do
            nil ->
              {tid, %{loop_id: lid, attempt: 1}}

            loop ->
              {tid, %{loop_id: lid, attempt: max(loop.current_attempt, 1)}}
          end
        end)
      )

    loop_ids = all_info |> Map.values() |> Enum.map(& &1.loop_id)
    step_roles = latest_step_roles_for_loops(loop_ids)

    Map.new(all_info, fn {tid, info} ->
      stage = Map.get(step_roles, info.loop_id, "pending")
      {tid, Map.put(info, :stage, stage)}
    end)
  end

  @doc """
  Returns the first task-loop ID for a ticket.
  """
  @spec first_loop_id(binary()) :: binary() | nil
  def first_loop_id(ticket_id) do
    ticket_id
    |> list_task_loops_for_ticket()
    |> List.first()
    |> case do
      nil -> nil
      loop -> loop.id
    end
  end

  @doc """
  Returns the first inspectable loop ID for a ticket.
  """
  @spec first_inspect_loop_id(binary()) :: binary() | nil
  def first_inspect_loop_id(ticket_id) do
    ticket_id
    |> list_loops_for_ticket()
    |> Enum.reject(&(&1.role == :hook))
    |> Enum.sort_by(fn loop -> {if(loop.role == :task, do: 0, else: 1), loop.inserted_at} end)
    |> List.first()
    |> case do
      nil -> nil
      loop -> loop.id
    end
  end

  @doc """
  Subscribes to loop-status events for a ticket.
  """
  @spec subscribe_ticket_loops(binary()) :: :ok | {:error, term()}
  def subscribe_ticket_loops(ticket_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, "ticket_loops:#{ticket_id}")
  end

  @doc """
  Subscribes to updates for a specific loop.
  """
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(loop_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, "loop:#{loop_id}")
  end

  # -- Step functions (replaces TaskLoopHistory) --

  @doc """
  Creates a loop step and broadcasts the update.
  """
  @spec create_step(map()) :: {:ok, LoopStep.t()} | {:error, Ecto.Changeset.t()}
  def create_step(attrs) do
    %LoopStep{}
    |> LoopStep.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, step} -> broadcast_history(step.loop_id)
      _ -> :ok
    end)
  end

  @doc """
  Completes a step by updating its status and optional fields, then broadcasts.
  """
  @spec complete_step(LoopStep.t(), map()) :: {:ok, LoopStep.t()} | {:error, Ecto.Changeset.t()}
  def complete_step(%LoopStep{} = step, attrs) do
    step
    |> LoopStep.changeset(Map.put(attrs, :finished_at, DateTime.utc_now()))
    |> Repo.update()
    |> tap(fn
      {:ok, step} -> broadcast_history(step.loop_id)
      _ -> :ok
    end)
  end

  @doc """
  Lists all steps for a loop, ordered by started_at ascending.
  """
  @spec list_steps_for_loop(binary()) :: [LoopStep.t()]
  def list_steps_for_loop(loop_id) do
    LoopStep
    |> where([s], s.loop_id == ^loop_id)
    |> order_by([s], asc: s.started_at)
    |> Repo.all()
  end

  @doc """
  Returns the currently running step for a loop, or nil.
  """
  @spec current_running_step(binary()) :: LoopStep.t() | nil
  def current_running_step(loop_id) do
    LoopStep
    |> where([s], s.loop_id == ^loop_id and s.status == "running")
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns the most recent step for a loop, or nil.
  """
  @spec latest_step(binary()) :: LoopStep.t() | nil
  def latest_step(loop_id) do
    LoopStep
    |> where([s], s.loop_id == ^loop_id)
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns the current phase for a loop by querying the latest step's role.
  Returns nil if no steps exist.
  """
  @spec current_phase(binary()) :: String.t() | nil
  def current_phase(loop_id) do
    case latest_step(loop_id) do
      nil -> nil
      step -> step.role
    end
  end

  @doc """
  Finds the last running step matching the given role and attempt, then completes it.
  """
  @spec complete_last_running(binary(), String.t(), integer(), map()) ::
          {:ok, LoopStep.t()} | :not_found
  def complete_last_running(loop_id, role, attempt, attrs) do
    step =
      LoopStep
      |> where(
        [s],
        s.loop_id == ^loop_id and s.role == ^role and s.attempt == ^attempt and
          s.status == "running"
      )
      |> order_by([s], desc: s.started_at)
      |> limit(1)
      |> Repo.one()

    case step do
      nil -> :not_found
      step -> complete_step(step, attrs)
    end
  end

  defp broadcast_history(loop_id) do
    history = list_steps_for_loop(loop_id)

    steps_as_maps =
      Enum.map(history, fn step ->
        %{
          id: step.id,
          role: step.role,
          attempt: step.attempt,
          status: step.status,
          session_id: step.session_id,
          exit_code: step.exit_code,
          verdict: step.verdict,
          feedback: step.feedback,
          feedback_path: step.feedback_path,
          error: step.error,
          started_at: step.started_at,
          finished_at: step.finished_at
        }
      end)

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      "loop:#{loop_id}",
      {:loop_history_updated, steps_as_maps}
    )
  end

  @doc """
  Deletes all loops (and their steps via DB cascade) for a ticket.
  Returns the number of deleted loops.
  """
  @spec delete_loops_for_ticket(binary()) :: {non_neg_integer(), nil}
  def delete_loops_for_ticket(ticket_id) do
    from(l in Loop, where: l.ticket_id == ^ticket_id)
    |> Repo.delete_all()
  end

  defp latest_step_roles_for_loops([]), do: %{}

  defp latest_step_roles_for_loops(loop_ids) do
    latest =
      from(s in LoopStep,
        where: s.loop_id in ^loop_ids,
        distinct: s.loop_id,
        order_by: [asc: s.loop_id, desc: s.started_at],
        select: {s.loop_id, s.role}
      )

    latest
    |> Repo.all()
    |> Map.new()
  end

  defp uuid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp uuid?(_), do: false
end
