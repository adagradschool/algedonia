defmodule Algedonia.Orchestrator do
  @moduledoc """
  GenServer managing decomposition as a maker-checker loop.

  When a user clicks "Start Work" on a ticket, the Orchestrator:
  1. Creates a synthetic DAG with a decompose loop
  2. Pushes `start_loop` (role=decompose) to an online daemon
  3. On decompose result: stores proposed DAG, creates checker loop
  4. On checker pass: creates the real DAG with loops from proposed data
  5. On checker fail with retries: re-runs decompose with feedback
  6. On max attempts exceeded: marks ticket as decomposition_failed
  """
  use GenServer

  alias Algedonia.{Daemons, Dags, Loops, Repo, Tickets}
  alias Algedonia.Dags.Dag

  @max_decompose_attempts 3

  # -- Client API --

  def start_link(opts \\ []) do
    {push_fn, opts} = Keyword.pop(opts, :push_fn, &default_push/3)

    GenServer.start_link(
      __MODULE__,
      %{push_fn: push_fn},
      Keyword.put_new(opts, :name, __MODULE__)
    )
  end

  @doc """
  Initiates decomposition for a ticket. Ticket must be in `:backlog` status.
  """
  @spec start_work(binary(), keyword()) :: :ok | {:error, term()}
  def start_work(ticket_id, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:start_work, ticket_id})
  end

  @doc """
  Handles a loop result from the daemon.
  """
  @spec handle_loop_result(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_loop_result(loop_id, payload, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      nil -> {:error, :orchestrator_not_running}
      pid -> GenServer.call(pid, {:loop_result, loop_id, payload})
    end
  end

  @doc """
  Handles a loop error from the daemon.
  """
  @spec handle_loop_error(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_loop_error(loop_id, error, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      nil -> {:error, :orchestrator_not_running}
      pid -> GenServer.call(pid, {:loop_error, loop_id, error})
    end
  end

  # -- Server Callbacks --

  @impl true
  def init(state) do
    {:ok, Map.put(state, :decompositions, %{})}
  end

  @impl true
  def handle_call({:start_work, ticket_id}, _from, state) do
    with {:ok, ticket} <- validate_backlog(ticket_id),
         {:ok, daemon} <- find_online_daemon(),
         {:ok, ticket} <- Tickets.update_ticket(ticket, %{status: :decomposing}),
         {:ok, dag} <- create_decompose_dag(ticket),
         {:ok, loop} <- create_decompose_loop(dag, daemon) do
      decomposition = %{
        ticket_id: ticket_id,
        dag_id: dag.id,
        loop_id: loop.id,
        daemon_name: daemon.name,
        attempt: 1,
        proposed_dag: nil,
        status: :decomposing
      }

      state = put_in(state, [:decompositions, ticket_id], decomposition)

      push_fn = state.push_fn

      push_fn.(daemon.name, loop.id, %{
        "role" => "decompose",
        "ticket_id" => ticket_id,
        "ticket" => ticket_context(ticket)
      })

      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:loop_result, loop_id, payload}, _from, state) do
    case find_decomposition_by_loop(state, loop_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {ticket_id, decomp} ->
        {result, state} = process_loop_result(decomp, ticket_id, payload, state)
        {:reply, result, state}
    end
  end

  def handle_call({:loop_error, loop_id, _error}, _from, state) do
    case find_decomposition_by_loop(state, loop_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {ticket_id, decomp} ->
        {result, state} = handle_failure(decomp, ticket_id, state)
        {:reply, result, state}
    end
  end

  # -- Internal Logic --

  defp process_loop_result(decomp, ticket_id, payload, state) do
    loop = Loops.get_loop!(decomp.loop_id)

    case loop.role do
      :decompose ->
        handle_decompose_result(decomp, ticket_id, payload, state)

      :decompose_checker ->
        handle_checker_result(decomp, ticket_id, payload, state)

      _ ->
        {:ok, state}
    end
  end

  defp handle_decompose_result(decomp, ticket_id, payload, state) do
    verdict = Map.get(payload, "verdict", "pass")
    dag_data = Map.get(payload, "dag")

    Loops.update_loop_status(Loops.get_loop!(decomp.loop_id), :passed)

    if verdict == "pass" && dag_data do
      {:ok, checker_loop} = create_checker_loop(decomp)

      decomp = %{
        decomp
        | proposed_dag: dag_data,
          loop_id: checker_loop.id,
          status: :checking
      }

      state = put_in(state, [:decompositions, ticket_id], decomp)
      push_fn = state.push_fn

      push_fn.(decomp.daemon_name, checker_loop.id, %{
        "role" => "decompose_checker",
        "ticket_id" => ticket_id,
        "ticket" => ticket_context(Tickets.get_ticket!(ticket_id)),
        "proposed_dag" => dag_data
      })

      {:ok, state}
    else
      handle_failure(decomp, ticket_id, state)
    end
  end

  defp handle_checker_result(decomp, ticket_id, payload, state) do
    verdict = Map.get(payload, "verdict", "pass")

    Loops.update_loop_status(Loops.get_loop!(decomp.loop_id), :passed)

    if verdict == "pass" do
      finalize_decomposition(decomp, ticket_id, state)
    else
      feedback = Map.get(payload, "feedback", "")
      retry_decompose(decomp, ticket_id, feedback, state)
    end
  end

  defp finalize_decomposition(decomp, ticket_id, state) do
    dag_attrs = %{ticket_id: ticket_id}

    # Delete the synthetic decompose DAG first
    old_dag = Dags.get_dag_by_ticket(ticket_id)
    if old_dag, do: Repo.delete(old_dag)

    case Dags.create_dag_with_loops(dag_attrs, decomp.proposed_dag) do
      {:ok, _dag} ->
        ticket = Tickets.get_ticket!(ticket_id)
        Tickets.update_ticket(ticket, %{status: :in_progress})
        state = update_in(state, [:decompositions], &Map.delete(&1, ticket_id))
        {:ok, state}

      {:error, _, _, _} ->
        mark_failed(ticket_id, state)
    end
  end

  defp retry_decompose(decomp, ticket_id, feedback, state) do
    new_attempt = decomp.attempt + 1

    if new_attempt > @max_decompose_attempts do
      Loops.update_loop_status(Loops.get_loop!(decomp.loop_id), :failed)
      mark_failed(ticket_id, state)
    else
      dag = Dags.get_dag_by_ticket(ticket_id)
      daemon = Daemons.get_daemon_by_name(decomp.daemon_name)
      {:ok, loop} = create_decompose_loop(dag, daemon)

      decomp = %{
        decomp
        | loop_id: loop.id,
          attempt: new_attempt,
          proposed_dag: nil,
          status: :decomposing
      }

      state = put_in(state, [:decompositions, ticket_id], decomp)
      push_fn = state.push_fn

      push_fn.(decomp.daemon_name, loop.id, %{
        "role" => "decompose",
        "ticket_id" => ticket_id,
        "ticket" => ticket_context(Tickets.get_ticket!(ticket_id)),
        "feedback" => feedback
      })

      {:ok, state}
    end
  end

  defp handle_failure(decomp, ticket_id, state) do
    new_attempt = decomp.attempt + 1

    if new_attempt > @max_decompose_attempts do
      mark_failed(ticket_id, state)
    else
      retry_decompose(decomp, ticket_id, "", state)
    end
  end

  defp mark_failed(ticket_id, state) do
    ticket = Tickets.get_ticket!(ticket_id)
    Tickets.update_ticket(ticket, %{status: :decomposition_failed})
    state = update_in(state, [:decompositions], &Map.delete(&1, ticket_id))
    {:ok, state}
  end

  defp validate_backlog(ticket_id) do
    ticket = Tickets.get_ticket!(ticket_id)

    if ticket.status == :backlog do
      {:ok, ticket}
    else
      {:error, :invalid_status}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp find_online_daemon do
    case Daemons.list_daemons() |> Enum.find(&(&1.status == :online)) do
      nil -> {:error, :no_online_daemon}
      daemon -> {:ok, daemon}
    end
  end

  defp create_decompose_dag(ticket) do
    %Dag{}
    |> Dag.changeset(%{ticket_id: ticket.id, status: :running})
    |> Repo.insert()
  end

  defp create_decompose_loop(dag, daemon) do
    Loops.create_loop(%{
      title: "Decompose ticket",
      dag_id: dag.id,
      role: :decompose,
      status: :running_maker,
      assigned_daemon_id: daemon.id
    })
  end

  defp create_checker_loop(decomp) do
    loop = Loops.get_loop!(decomp.loop_id)

    Loops.create_loop(%{
      title: "Verify decomposition",
      dag_id: loop.dag_id,
      role: :decompose_checker,
      status: :running_checker,
      assigned_daemon_id: loop.assigned_daemon_id
    })
  end

  defp ticket_context(ticket) do
    %{
      "title" => ticket.title,
      "description" => ticket.description,
      "acceptance_criteria" => ticket.acceptance_criteria,
      "rubric" => ticket.rubric,
      "type" => to_string(ticket.type),
      "priority" => ticket.priority
    }
  end

  defp find_decomposition_by_loop(state, loop_id) do
    Enum.find_value(state.decompositions, fn {ticket_id, decomp} ->
      if decomp.loop_id == loop_id, do: {ticket_id, decomp}
    end)
  end

  defp default_push(daemon_name, loop_id, opts) do
    AlgedoniaWeb.DaemonChannel.push_start_loop(daemon_name, loop_id, opts)
  end
end
