defmodule Algedonia.Loops do
  @moduledoc """
  Context for loop management — CRUD and status updates with PubSub broadcasts.
  """
  import Ecto.Query

  alias Algedonia.Loops.Loop
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
  Gets a loop with its DAG and ticket preloaded. Raises if not found.
  """
  @spec get_loop_with_ticket!(binary()) :: Loop.t()
  def get_loop_with_ticket!(id) do
    get_loop!(id) |> Repo.preload(dag: :ticket)
  end

  @doc """
  Gets a loop by reference with DAG and ticket preloaded. Raises if not found.
  """
  @spec get_loop_with_ticket_by_ref!(binary()) :: Loop.t()
  def get_loop_with_ticket_by_ref!(ref) do
    get_loop_by_ref!(ref) |> Repo.preload(dag: :ticket)
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
        loop = Repo.preload(loop, dag: :ticket)
        ticket_id = loop.dag.ticket_id

        Phoenix.PubSub.broadcast(
          Algedonia.PubSub,
          "dag:#{ticket_id}",
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
  Preloads a loop's DAG and ticket associations.
  """
  @spec preload_ticket(Loop.t()) :: Loop.t()
  def preload_ticket(%Loop{} = loop), do: Repo.preload(loop, dag: :ticket)

  @doc """
  Preloads a loop with its DAG and ticket.
  """
  @spec preload_with_ticket(Loop.t()) :: Loop.t()
  def preload_with_ticket(%Loop{} = loop), do: Repo.preload(loop, dag: :ticket)

  @doc """
  Preloads a loop with its DAG, ticket, and workspace.
  """
  @spec preload_with_workspace(Loop.t()) :: Loop.t()
  def preload_with_workspace(%Loop{} = loop), do: Repo.preload(loop, dag: [ticket: :workspace])

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

      updated = Repo.preload(updated, :dag)

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        "dag:#{updated.dag.ticket_id}",
        {:loop_status_changed, updated}
      )

      updated
    end)
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
