defmodule Algedonia.Loops do
  @moduledoc """
  Context for loop management — CRUD and status updates with PubSub broadcasts.
  """
  import Ecto.Query

  alias Algedonia.Loops.{Loop, LoopStep}
  alias Algedonia.PubSub.Topics
  alias Algedonia.Repo
  alias Algedonia.TenantScope

  @doc """
  Gets a single loop. Raises `Ecto.NoResultsError` if not found.
  """
  @spec get_loop!(Algedonia.Types.id()) :: Loop.t()
  def get_loop!(id), do: Repo.get!(Loop, id)

  @doc """
  Gets a single loop, returns nil if not found.
  """
  @spec get_loop(Algedonia.Types.id()) :: Loop.t() | nil
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
  @spec get_loop_with_ticket!(Algedonia.Types.id()) :: Loop.t()
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
  Finds an existing pending/running planning loop for a ticket, or creates one
  with a single planning step.
  """
  @spec find_or_create_planning_loop(Algedonia.Tickets.Ticket.t()) ::
          {:ok, Loop.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_planning_loop(ticket) do
    existing =
      Loop
      |> where([l], l.ticket_id == ^ticket.id and l.role == :planning)
      |> where([l], l.status in [:pending, :running])
      |> order_by([l], desc: l.inserted_at)
      |> limit(1)
      |> Repo.one()

    case existing do
      %Loop{} = loop ->
        {:ok, loop}

      nil ->
        with {:ok, loop} <-
               create_loop(%{
                 workspace_id: ticket.workspace_id,
                 ticket_id: ticket.id,
                 title: "Planning: #{ticket.title}",
                 role: :planning,
                 status: :pending,
                 max_attempts: 1
               }),
             {:ok, _step} <-
               create_step(%{
                 loop_id: loop.id,
                 role: "planning",
                 attempt: 1,
                 status: "running",
                 started_at: DateTime.utc_now()
               }) do
          {:ok, loop}
        end
    end
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
          Topics.ticket_loops(loop.workspace_id, ticket_id),
          {:loop_status_changed, loop}
        )

        Phoenix.PubSub.broadcast(
          Algedonia.PubSub,
          Topics.loop(loop.workspace_id, loop.id),
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
          Topics.loop(loop.workspace_id, loop.id),
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
  @spec list_hook_loops_for_ticket(Algedonia.Types.id()) :: [Loop.t()]
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
  @spec requeue_running_task_loops_for_daemon(Algedonia.Types.id()) :: [Loop.t()]
  def requeue_running_task_loops_for_daemon(daemon_id) when is_binary(daemon_id) do
    daemon_id
    |> running_loop_workspace_ids_for_daemon()
    |> Enum.flat_map(fn workspace_id ->
      TenantScope.with_workspace(workspace_id, fn ->
        Loop
        |> where([l], l.assigned_daemon_id == ^daemon_id and l.status == :running)
        |> Repo.all()
      end)
    end)
    |> Enum.map(fn loop ->
      interrupt_running_steps(loop.id)

      new_status = if loop.role == :task, do: :pending, else: :failed

      {:ok, updated} =
        update_loop(loop, %{
          status: new_status,
          assigned_daemon_id: nil
        })

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.ticket_loops(updated.workspace_id, updated.ticket_id),
        {:loop_status_changed, updated}
      )

      updated
    end)
  end

  @doc """
  Marks all running steps for a loop as interrupted.
  """
  @spec interrupt_running_steps(Algedonia.Types.id()) :: {non_neg_integer(), nil}
  def interrupt_running_steps(loop_id) do
    now = DateTime.utc_now()

    LoopStep
    |> where([s], s.loop_id == ^loop_id and s.status == "running")
    |> Repo.update_all(set: [status: "interrupted", finished_at: now])
  end

  @doc """
  Returns running loops assigned to a daemon.
  """
  @spec list_running_loops_for_daemon(Algedonia.Types.id()) :: [Loop.t()]
  def list_running_loops_for_daemon(daemon_id) do
    daemon_id
    |> running_loop_workspace_ids_for_daemon()
    |> Enum.flat_map(fn workspace_id ->
      TenantScope.with_workspace(workspace_id, fn ->
        Loop
        |> where([l], l.assigned_daemon_id == ^daemon_id and l.status == :running)
        |> Repo.all()
      end)
    end)
  end

  @doc """
  Returns pending task loops with no assigned daemon.
  """
  @spec list_pending_unassigned_task_loops() :: [Loop.t()]
  def list_pending_unassigned_task_loops do
    pending_unassigned_task_workspace_ids()
    |> Enum.flat_map(fn workspace_id ->
      TenantScope.with_workspace(workspace_id, fn ->
        Loop
        |> where([l], l.role == :task and l.status == :pending and is_nil(l.assigned_daemon_id))
        |> order_by([l], asc: l.inserted_at)
        |> Repo.all()
      end)
    end)
  end

  @doc """
  Returns all loops for a ticket, ordered by insertion time.
  """
  @spec list_loops_for_ticket(Algedonia.Types.id()) :: [Loop.t()]
  def list_loops_for_ticket(ticket_id) do
    Loop
    |> where([l], l.ticket_id == ^ticket_id)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns all task loops for a ticket, ordered by insertion time.
  """
  @spec list_task_loops_for_ticket(Algedonia.Types.id()) :: [Loop.t()]
  def list_task_loops_for_ticket(ticket_id) do
    Loop
    |> where([l], l.ticket_id == ^ticket_id and l.role == :task)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns all review loops for a ticket, ordered by insertion time.
  """
  @spec list_review_loops_for_ticket(Algedonia.Types.id()) :: [Loop.t()]
  def list_review_loops_for_ticket(ticket_id) do
    Loop
    |> where([l], l.ticket_id == ^ticket_id and l.role == :review)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns all planning loops for a ticket, ordered by insertion time.
  """
  @spec list_planning_loops_for_ticket(Algedonia.Types.id()) :: [Loop.t()]
  def list_planning_loops_for_ticket(ticket_id) do
    Loop
    |> where([l], l.ticket_id == ^ticket_id and l.role == :planning)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns the first task-loop ID for each ticket ID.
  """
  @spec first_loop_ids_for_tickets([Algedonia.Types.id()]) :: %{
          Algedonia.Types.id() => Algedonia.Types.id()
        }
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
  @spec first_inspect_loop_ids_for_tickets([Algedonia.Types.id()]) :: %{
          Algedonia.Types.id() => Algedonia.Types.id()
        }
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
  @spec active_loop_info_for_tickets([Algedonia.Types.id()]) :: %{
          Algedonia.Types.id() => %{
            loop_id: Algedonia.Types.id(),
            stage: String.t(),
            attempt: integer()
          }
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
  @spec first_loop_id(Algedonia.Types.id()) :: Algedonia.Types.id() | nil
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
  @spec first_inspect_loop_id(Algedonia.Types.id()) :: Algedonia.Types.id() | nil
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
  Returns the active review-loop ID for a ticket, falling back to the most recent review loop.
  """
  @spec first_review_loop_id(Algedonia.Types.id()) :: Algedonia.Types.id() | nil
  def first_review_loop_id(ticket_id) do
    review_loops = list_review_loops_for_ticket(ticket_id)

    (Enum.find(review_loops, &(&1.status in [:pending, :running])) || List.last(review_loops))
    |> case do
      nil -> nil
      loop -> loop.id
    end
  end

  @doc """
  Subscribes to loop-status events for a ticket.
  """
  @spec subscribe_ticket_loops(Algedonia.Types.id(), Algedonia.Types.id()) ::
          :ok | {:error, term()}
  def subscribe_ticket_loops(workspace_id, ticket_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, Topics.ticket_loops(workspace_id, ticket_id))
  end

  @doc """
  Subscribes to updates for a specific loop.
  """
  @spec subscribe(Algedonia.Types.id(), Algedonia.Types.id()) :: :ok | {:error, term()}
  def subscribe(workspace_id, loop_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, Topics.loop(workspace_id, loop_id))
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
  Resumes the latest interrupted step for the given attempt and roles, if present.
  """
  @spec maybe_resume_interrupted_step(Algedonia.Types.id(), integer(), [String.t()], map()) ::
          {:ok, LoopStep.t()} | {:error, Ecto.Changeset.t()} | :noop
  def maybe_resume_interrupted_step(loop_id, attempt, roles, attrs \\ %{})
      when is_binary(loop_id) and is_integer(attempt) and is_list(roles) do
    case latest_step(loop_id) do
      %LoopStep{status: "interrupted", attempt: ^attempt, role: role} = step ->
        if role in roles, do: resume_step(step, attrs), else: :noop

      _ ->
        :noop
    end
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
  Resumes an interrupted step by returning it to running state and clearing any completion fields.
  """
  @spec resume_step(LoopStep.t(), map()) :: {:ok, LoopStep.t()} | {:error, Ecto.Changeset.t()}
  def resume_step(%LoopStep{} = step, attrs \\ %{}) do
    defaults = %{
      status: "running",
      session_id: nil,
      exit_code: nil,
      verdict: nil,
      summary: nil,
      feedback: nil,
      feedback_path: nil,
      error: nil,
      finished_at: nil
    }

    step
    |> LoopStep.changeset(Map.merge(defaults, attrs))
    |> Repo.update()
    |> tap(fn
      {:ok, step} -> broadcast_history(step.loop_id)
      _ -> :ok
    end)
  end

  @doc """
  Lists all steps for a loop, ordered by started_at ascending.
  """
  @spec list_steps_for_loop(Algedonia.Types.id()) :: [LoopStep.t()]
  def list_steps_for_loop(loop_id) do
    LoopStep
    |> where([s], s.loop_id == ^loop_id)
    |> order_by([s], asc: s.started_at)
    |> Repo.all()
  end

  @doc """
  Returns the currently running step for a loop, or nil.
  """
  @spec current_running_step(Algedonia.Types.id()) :: LoopStep.t() | nil
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
  @spec latest_step(Algedonia.Types.id()) :: LoopStep.t() | nil
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
  @spec current_phase(Algedonia.Types.id()) :: String.t() | nil
  def current_phase(loop_id) do
    case latest_step(loop_id) do
      nil -> nil
      step -> step.role
    end
  end

  @doc """
  Finds the last running step matching the given role and attempt, then completes it.
  """
  @spec complete_last_running(Algedonia.Types.id(), String.t(), integer(), map()) ::
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
          step_id: step.step_id,
          skill: step.skill,
          order_index: step.order_index,
          required: step.required,
          status: step.status,
          session_id: step.session_id,
          exit_code: step.exit_code,
          verdict: step.verdict,
          summary: step.summary,
          feedback: step.feedback,
          feedback_path: step.feedback_path,
          error: step.error,
          started_at: step.started_at,
          finished_at: step.finished_at
        }
      end)

    if workspace_id = loop_workspace_id(loop_id) do
      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.loop(workspace_id, loop_id),
        {:loop_history_updated, steps_as_maps}
      )
    end
  end

  @doc """
  Deletes all loops (and their steps via DB cascade) for a ticket.
  Returns the number of deleted loops.
  """
  @spec delete_loops_for_ticket(Algedonia.Types.id()) :: {non_neg_integer(), nil}
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

  defp running_loop_workspace_ids_for_daemon(daemon_id) do
    daemon_id = Ecto.UUID.dump!(daemon_id)

    workspace_ids_for_query(
      """
      SELECT DISTINCT workspace_id::text
      FROM loops
      WHERE assigned_daemon_id = $1 AND status = 'running'
      """,
      [daemon_id]
    )
  end

  defp pending_unassigned_task_workspace_ids do
    workspace_ids_for_query(
      """
      SELECT DISTINCT workspace_id::text
      FROM loops
      WHERE role = 'task' AND status = 'pending' AND assigned_daemon_id IS NULL
      """,
      []
    )
  end

  defp workspace_ids_for_query(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [workspace_id] -> workspace_id end)
        |> Enum.filter(&is_binary/1)

      _ ->
        []
    end
  end

  defp loop_workspace_id(loop_id) do
    Loop
    |> where([l], l.id == ^loop_id)
    |> select([l], l.workspace_id)
    |> Repo.one()
  end

  defp uuid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp uuid?(_), do: false
end
