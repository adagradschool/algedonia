defmodule Algedonia.DecomposeOrchestrator do
  @moduledoc """
  GenServer managing the decomposition lifecycle for tickets.
  Handles start_work → decompose → checker → finalize DAG.
  """
  use GenServer

  alias Algedonia.{Agents, Daemons, Dags, Loops, Tickets}
  alias Algedonia.PromptBuilder

  @max_decompose_attempts 3

  # -- Client API --

  @doc "Starts the DecomposeOrchestrator GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {push_fn, opts} = Keyword.pop(opts, :push_fn, &default_push/3)

    GenServer.start_link(
      __MODULE__,
      %{push_fn: push_fn},
      Keyword.put_new(opts, :name, __MODULE__)
    )
  end

  @doc "Initiates decomposition for a ticket. Ticket must be in `:backlog` status."
  @spec start_work(binary(), keyword()) :: :ok | {:error, term()}
  def start_work(ticket_id, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:start_work, ticket_id})
  end

  @doc "Handles a loop result from the daemon (decompose or decompose_checker)."
  @spec handle_loop_result(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_loop_result(loop_id, payload, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      nil -> {:error, :orchestrator_not_running}
      pid -> GenServer.call(pid, {:loop_result, loop_id, payload})
    end
  end

  @doc "Handles a loop error from the daemon."
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
  def init(state), do: {:ok, Map.put(state, :decompositions, %{})}

  @impl true
  def handle_call({:start_work, ticket_id}, _from, state) do
    with {:ok, ticket} <- validate_backlog(ticket_id),
         {:ok, daemon} <- Daemons.find_online(),
         {:ok, ticket} <- Tickets.update_ticket(ticket, %{status: :planning}),
         {:ok, dag} <- Dags.create_dag(%{ticket_id: ticket.id, status: :running}),
         {:ok, loop} <- create_decompose_loop(dag, daemon) do
      decomp = %{
        ticket_id: ticket_id,
        dag_id: dag.id,
        loop_id: loop.id,
        daemon_name: daemon.name,
        attempt: 1,
        proposed_dag: nil,
        status: :planning
      }

      state = put_in(state, [:decompositions, ticket_id], decomp)

      state.push_fn.(daemon.name, loop.id, %{
        "role" => "decompose",
        "agent_type" => Agents.ticket_agent_type(ticket),
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

      {tid, decomp} ->
        {result, state} = process_loop_result(decomp, tid, payload, state)
        {:reply, result, state}
    end
  end

  def handle_call({:loop_error, loop_id, _error}, _from, state) do
    case find_decomposition_by_loop(state, loop_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {tid, decomp} ->
        {result, state} = handle_failure(decomp, tid, state)
        {:reply, result, state}
    end
  end

  # -- Internal Logic --

  defp process_loop_result(decomp, ticket_id, payload, state) do
    loop = Loops.get_loop!(decomp.loop_id)

    case loop.role do
      :decompose -> handle_decompose_result(decomp, ticket_id, payload, state)
      :decompose_checker -> handle_checker_result(decomp, ticket_id, payload, state)
      _ -> {:ok, state}
    end
  end

  defp handle_decompose_result(decomp, ticket_id, payload, state) do
    verdict = Map.get(payload, "verdict", "pass")
    dag_data = Map.get(payload, "dag")
    Loops.update_loop_status(Loops.get_loop!(decomp.loop_id), :passed)

    if verdict == "pass" && dag_data do
      {:ok, checker_loop} = create_checker_loop(decomp)
      decomp = %{decomp | proposed_dag: dag_data, loop_id: checker_loop.id, status: :checking}
      state = put_in(state, [:decompositions, ticket_id], decomp)
      ticket = Tickets.get_ticket!(ticket_id)

      state.push_fn.(decomp.daemon_name, checker_loop.id, %{
        "role" => "decompose_checker",
        "agent_type" => Agents.ticket_agent_type(ticket),
        "ticket_id" => ticket_id,
        "ticket" => ticket_context(ticket),
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
      retry_decompose(decomp, ticket_id, Map.get(payload, "feedback", ""), state)
    end
  end

  defp finalize_decomposition(decomp, ticket_id, state) do
    old_dag = Dags.get_dag_by_ticket(ticket_id)
    if old_dag, do: Dags.delete_dag(old_dag)

    case Dags.create_dag_with_loops(%{ticket_id: ticket_id}, decomp.proposed_dag) do
      {:ok, _dag} ->
        ticket = Tickets.get_ticket!(ticket_id)
        Tickets.update_ticket(ticket, %{status: :in_progress})
        {:ok, update_in(state, [:decompositions], &Map.delete(&1, ticket_id))}

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
          status: :planning
      }

      state = put_in(state, [:decompositions, ticket_id], decomp)
      ticket = Tickets.get_ticket!(ticket_id)

      state.push_fn.(decomp.daemon_name, loop.id, %{
        "role" => "decompose",
        "agent_type" => Agents.ticket_agent_type(ticket),
        "ticket_id" => ticket_id,
        "ticket" => ticket_context(ticket),
        "feedback" => feedback
      })

      {:ok, state}
    end
  end

  defp handle_failure(decomp, ticket_id, state) do
    if decomp.attempt + 1 > @max_decompose_attempts do
      mark_failed(ticket_id, state)
    else
      retry_decompose(decomp, ticket_id, "", state)
    end
  end

  defp mark_failed(ticket_id, state) do
    ticket = Tickets.get_ticket!(ticket_id)
    Tickets.update_ticket(ticket, %{status: :halted})
    {:ok, update_in(state, [:decompositions], &Map.delete(&1, ticket_id))}
  end

  defp validate_backlog(ticket_id) do
    ticket = Tickets.get_ticket!(ticket_id)
    if ticket.status == :backlog, do: {:ok, ticket}, else: {:error, :invalid_status}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
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
    comments = Tickets.list_comments(ticket.id)

    %{
      "title" => ticket.title,
      "description" => ticket.description,
      "acceptance_criteria" => ticket.acceptance_criteria,
      "rubric" => ticket.rubric,
      "type" => to_string(ticket.type),
      "priority" => ticket.priority,
      "comments" => PromptBuilder.non_empty_list(format_comments_data(comments))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp format_comments_data([]), do: []
  defp format_comments_data(comments), do: Enum.map(comments, &comment_to_map/1)

  defp comment_to_map(comment) do
    replies =
      case comment.replies do
        %Ecto.Association.NotLoaded{} -> []
        replies -> Enum.map(replies, &comment_to_map/1)
      end

    %{"author" => comment.author, "body" => comment.body, "replies" => replies}
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
