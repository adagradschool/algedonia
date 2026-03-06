defmodule Algedonia.Loops do
  @moduledoc """
  Context for loop management — CRUD and status updates with PubSub broadcasts.
  """
  import Ecto.Query

  alias Algedonia.Loops.Loop
  alias Algedonia.Repo

  @status_to_stage %{
    running_checker: "checker",
    passed: "completed",
    failed: "failed"
  }

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
        l.status in [:running_maker, :running_checker]
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
    terminal = [:passed, :failed, :escalated, :skipped, :resolved]

    active =
      from(l in Loop,
        where: l.ticket_id in ^ticket_ids and l.role != :hook and l.status not in ^terminal,
        distinct: l.ticket_id,
        order_by: [asc: l.ticket_id, asc: l.inserted_at],
        select: {l.ticket_id, l.id, l.status, l.current_attempt}
      )
      |> Repo.all()
      |> Map.new(fn {tid, lid, status, attempt} ->
        {tid, %{loop_id: lid, stage: stage_for_status(status), attempt: max(attempt, 1)}}
      end)

    missing = ticket_ids -- Map.keys(active)
    fallback = first_inspect_loop_ids_for_tickets(missing)

    Map.merge(
      active,
      Map.new(fallback, fn {tid, lid} ->
        case get_loop(lid) do
          nil ->
            {tid, %{loop_id: lid, stage: "maker", attempt: 1}}

          loop ->
            {tid,
             %{
               loop_id: lid,
               stage: stage_for_status(loop.status),
               attempt: max(loop.current_attempt, 1)
             }}
        end
      end)
    )
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
  Returns the stage string for a loop status.
  """
  @spec stage_for_status(atom()) :: String.t()
  def stage_for_status(status), do: Map.get(@status_to_stage, status, "maker")

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

  defp uuid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp uuid?(_), do: false
end
