defmodule Algedonia.Dags do
  @moduledoc """
  Context for DAG management — creation, queries, and PubSub broadcasts.
  """
  import Ecto.Query

  alias Algedonia.Dags.Dag
  alias Algedonia.Loops
  alias Algedonia.Loops.{Loop, LoopDependency}
  alias Algedonia.Repo
  alias Ecto.Multi

  @status_to_stage %{
    running_checker: "checker",
    passed: "completed",
    failed: "failed"
  }

  @doc """
  Creates a DAG with loops and dependencies atomically.

  `dag_attrs` must include `:ticket_id`.
  `dag_data` is a map with:
    - `"loops"` — list of loop maps with `"temp_id"`, `"title"`, etc.
    - `"dependencies"` — list of `%{"from" => temp_id, "to" => temp_id}`

  Temporary IDs from the decompose agent are mapped to real UUIDs.
  """
  @spec create_dag_with_loops(map(), map()) :: {:ok, Dag.t()} | {:error, atom(), term(), map()}
  def create_dag_with_loops(dag_attrs, dag_data) do
    loops_data = Map.get(dag_data, "loops", [])
    deps_data = Map.get(dag_data, "dependencies", [])

    multi =
      Multi.new()
      |> Multi.insert(:dag, Dag.changeset(%Dag{}, dag_attrs))
      |> Multi.run(:loops, fn repo, %{dag: dag} ->
        insert_loops(repo, dag, loops_data)
      end)
      |> Multi.run(:dependencies, fn repo, %{loops: id_map} ->
        insert_dependencies(repo, id_map, deps_data)
      end)

    case Repo.transaction(multi) do
      {:ok, %{dag: dag}} ->
        dag = Repo.preload(dag, :loops)
        broadcast(dag.ticket_id, {:dag_created, dag})
        {:ok, dag}

      {:error, step, changeset, _changes} ->
        {:error, step, changeset, %{}}
    end
  end

  defp insert_loops(repo, dag, loops_data) do
    {id_map, _} =
      Enum.reduce(loops_data, {%{}, []}, fn loop_data, {map, _acc} ->
        temp_id = Map.get(loop_data, "temp_id", Ecto.UUID.generate())

        attrs =
          loop_data
          |> Map.drop(["temp_id"])
          |> Map.put("dag_id", dag.id)
          |> atomize_loop_attrs()

        changeset = Loop.changeset(%Loop{}, attrs)

        case repo.insert(changeset) do
          {:ok, loop} ->
            {Map.put(map, temp_id, loop.id), []}

          {:error, changeset} ->
            throw({:insert_loop_error, changeset})
        end
      end)

    {:ok, id_map}
  catch
    {:insert_loop_error, changeset} -> {:error, changeset}
  end

  defp insert_dependencies(repo, id_map, deps_data) do
    deps =
      Enum.map(deps_data, fn dep ->
        upstream_id = Map.fetch!(id_map, dep["from"])
        downstream_id = Map.fetch!(id_map, dep["to"])

        changeset =
          LoopDependency.changeset(%LoopDependency{}, %{
            upstream_loop_id: upstream_id,
            downstream_loop_id: downstream_id
          })

        case repo.insert(changeset) do
          {:ok, d} -> d
          {:error, changeset} -> throw({:insert_dep_error, changeset})
        end
      end)

    {:ok, deps}
  catch
    {:insert_dep_error, changeset} -> {:error, changeset}
  end

  defp atomize_loop_attrs(attrs) do
    %{
      title: attrs["title"],
      description: attrs["description"],
      role: attrs["role"] || "task",
      manual_gate: attrs["manual_gate"] || false,
      max_attempts: attrs["max_attempts"] || 10,
      rubric: attrs["rubric"],
      dag_id: attrs["dag_id"]
    }
  end

  @doc """
  Creates a single DAG from the given attributes.
  """
  @spec create_dag(map()) :: {:ok, Dag.t()} | {:error, Ecto.Changeset.t()}
  def create_dag(attrs) do
    %Dag{}
    |> Dag.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a DAG.
  """
  @spec delete_dag(Dag.t()) :: {:ok, Dag.t()} | {:error, Ecto.Changeset.t()}
  def delete_dag(%Dag{} = dag) do
    Repo.delete(dag)
  end

  @doc """
  Returns a map of ticket_id => first task-loop id for the given ticket IDs.
  """
  @spec first_loop_ids_for_tickets([binary()]) :: %{binary() => binary()}
  def first_loop_ids_for_tickets([]), do: %{}

  def first_loop_ids_for_tickets(ticket_ids) do
    from(d in Dag,
      join: l in assoc(d, :loops),
      where: l.role == :task,
      where: d.ticket_id in ^ticket_ids,
      distinct: d.ticket_id,
      order_by: [asc: d.ticket_id, asc: l.inserted_at],
      select: {d.ticket_id, l.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns a map of ticket_id => first inspectable loop id.

  Prefers task loops; falls back to non-hook loops for legacy tickets.
  """
  @spec first_inspect_loop_ids_for_tickets([binary()]) :: %{binary() => binary()}
  def first_inspect_loop_ids_for_tickets([]), do: %{}

  def first_inspect_loop_ids_for_tickets(ticket_ids) do
    from(d in Dag,
      join: l in assoc(d, :loops),
      where: d.ticket_id in ^ticket_ids and l.role != :hook,
      order_by: [
        asc: d.ticket_id,
        asc: fragment("CASE WHEN ? = ? THEN 0 ELSE 1 END", l.role, ^"task"),
        asc: l.inserted_at
      ],
      select: {d.ticket_id, l.id}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {ticket_id, loop_id}, acc ->
      Map.put_new(acc, ticket_id, loop_id)
    end)
  end

  @doc """
  Returns a map of ticket_id => loop info for the given ticket IDs.

  For each ticket, finds the active (non-terminal) loop and returns its ID,
  stage, and attempt. Falls back to the first inspectable loop with defaults.
  """
  @spec active_loop_info_for_tickets([binary()]) :: %{
          binary() => %{loop_id: binary(), stage: String.t(), attempt: integer()}
        }
  def active_loop_info_for_tickets([]), do: %{}

  def active_loop_info_for_tickets(ticket_ids) do
    terminal = [:passed, :failed, :escalated, :skipped, :resolved]

    active =
      from(d in Dag,
        join: l in assoc(d, :loops),
        where: d.ticket_id in ^ticket_ids and l.role != :hook and l.status not in ^terminal,
        distinct: d.ticket_id,
        order_by: [asc: d.ticket_id, asc: l.inserted_at],
        select: {d.ticket_id, l.id, l.status, l.current_attempt}
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
        case Loops.get_loop(lid) do
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
  Returns the stage string for a given loop status atom.
  """
  @spec stage_for_status(atom()) :: String.t()
  def stage_for_status(status), do: Map.get(@status_to_stage, status, "maker")

  @doc """
  Returns the first task-loop ID for a ticket, or nil if no DAG/task loops exist.
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

  Prefers task loops; falls back to non-hook loops for legacy tickets.
  """
  @spec first_inspect_loop_id(binary()) :: binary() | nil
  def first_inspect_loop_id(ticket_id) do
    ticket_id
    |> list_inspectable_loops_for_ticket()
    |> List.first()
    |> case do
      nil -> nil
      loop -> loop.id
    end
  end

  @doc """
  Gets the DAG for a ticket, preloading loops.
  """
  @spec get_dag_by_ticket(binary()) :: Dag.t() | nil
  def get_dag_by_ticket(ticket_id) do
    Dag
    |> where([d], d.ticket_id == ^ticket_id)
    |> preload(:loops)
    |> Repo.one()
  end

  @doc """
  Updates a DAG's status.
  """
  @spec update_dag_status(Dag.t(), atom()) :: {:ok, Dag.t()} | {:error, Ecto.Changeset.t()}
  def update_dag_status(%Dag{} = dag, status) do
    dag
    |> Dag.changeset(%{status: status})
    |> Repo.update()
    |> tap(fn
      {:ok, dag} -> broadcast(dag.ticket_id, {:dag_updated, dag})
      _ -> :ok
    end)
  end

  @doc """
  Lists all loops for a DAG, ordered by insertion time.
  """
  @spec list_loops_for_dag(binary()) :: [Loop.t()]
  def list_loops_for_dag(dag_id) do
    Loop
    |> where([l], l.dag_id == ^dag_id)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists all dependencies for a DAG's loops.
  """
  @spec list_dependencies_for_dag(binary()) :: [LoopDependency.t()]
  def list_dependencies_for_dag(dag_id) do
    loop_ids = from(l in Loop, where: l.dag_id == ^dag_id, select: l.id)

    LoopDependency
    |> where([d], d.upstream_loop_id in subquery(loop_ids))
    |> Repo.all()
  end

  @doc """
  Subscribes to DAG events for a ticket.
  """
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(ticket_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, "dag:#{ticket_id}")
  end

  defp broadcast(ticket_id, message) do
    Phoenix.PubSub.broadcast(Algedonia.PubSub, "dag:#{ticket_id}", message)
  end

  defp list_task_loops_for_ticket(ticket_id) do
    from(l in Loop,
      join: d in Dag,
      on: l.dag_id == d.id,
      where: d.ticket_id == ^ticket_id and l.role == :task,
      order_by: [asc: l.inserted_at]
    )
    |> Repo.all()
  end

  defp list_inspectable_loops_for_ticket(ticket_id) do
    from(l in Loop,
      join: d in Dag,
      on: l.dag_id == d.id,
      where: d.ticket_id == ^ticket_id and l.role != :hook,
      order_by: [
        asc: fragment("CASE WHEN ? = ? THEN 0 ELSE 1 END", l.role, ^"task"),
        asc: l.inserted_at
      ]
    )
    |> Repo.all()
  end
end
