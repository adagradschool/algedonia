defmodule Algedonia.Orchestrator do
  @moduledoc """
  GenServer managing decomposition as a maker-checker loop.

  When a user clicks "Start Work" on a ticket, the Orchestrator:
  1. Creates a synthetic DAG with a decompose loop
  2. Pushes `start_loop` (role=decompose) to an online daemon
  3. On decompose result: stores proposed DAG, creates checker loop
  4. On checker pass: creates the real DAG with loops from proposed data
  5. On checker fail with retries: re-runs decompose with feedback
  6. On max attempts exceeded: marks ticket as halted
  """
  use GenServer

  alias Algedonia.{Agents, CheckerHandoff, Daemons, Dags, InlineReviews, Loops, Repo, Tickets}
  alias Algedonia.Dags.Dag

  @max_decompose_attempts 3
  @max_checker_handoff_repairs 2

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

  @doc """
  Handles an attempt completion from the daemon.
  """
  @spec handle_attempt_complete(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_attempt_complete(loop_id, payload, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    daemon_name = Keyword.get(opts, :daemon_name)

    case GenServer.whereis(name) do
      nil -> {:error, :orchestrator_not_running}
      pid -> GenServer.call(pid, {:attempt_complete, loop_id, payload, daemon_name})
    end
  end

  @doc """
  Starts a task loop maker run.
  """
  @spec start_task_loop(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def start_task_loop(loop_id, daemon_name, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:start_task_loop, loop_id, daemon_name, opts})
  end

  @doc """
  Returns in-memory history for a loop's maker/checker spin-ups.
  """
  @spec get_loop_history(binary(), keyword()) :: [map()]
  def get_loop_history(loop_id, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      nil -> []
      pid -> GenServer.call(pid, {:get_loop_history, loop_id})
    end
  end

  @doc """
  Returns the currently running step terminal id for a loop, if one exists.
  """
  @spec current_step_terminal_id(binary(), keyword()) :: binary() | nil
  def current_step_terminal_id(loop_id, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      nil -> nil
      pid -> GenServer.call(pid, {:current_step_terminal_id, loop_id})
    end
  end

  @doc """
  Returns the latest step terminal id for a loop, if history exists.
  """
  @spec latest_step_terminal_id(binary(), keyword()) :: binary() | nil
  def latest_step_terminal_id(loop_id, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.whereis(name) do
      nil -> nil
      pid -> GenServer.call(pid, {:latest_step_terminal_id, loop_id})
    end
  end

  # -- Server Callbacks --

  @impl true
  def init(state) do
    {:ok,
     state
     |> Map.put(:decompositions, %{})
     |> Map.put(:task_history, %{})
     |> Map.put(:checker_handoff_repairs, %{})
     |> Map.put(:task_run_config, %{})}
  end

  @impl true
  def handle_call({:start_work, ticket_id}, _from, state) do
    with {:ok, ticket} <- validate_backlog(ticket_id),
         {:ok, daemon} <- find_online_daemon(),
         {:ok, ticket} <- Tickets.update_ticket(ticket, %{status: :planning}),
         {:ok, dag} <- create_decompose_dag(ticket),
         {:ok, loop} <- create_decompose_loop(dag, daemon) do
      decomposition = %{
        ticket_id: ticket_id,
        dag_id: dag.id,
        loop_id: loop.id,
        daemon_name: daemon.name,
        attempt: 1,
        proposed_dag: nil,
        status: :planning
      }

      state = put_in(state, [:decompositions, ticket_id], decomposition)

      push_fn = state.push_fn

      push_fn.(daemon.name, loop.id, %{
        "role" => "decompose",
        "agent_type" => ticket_agent_type(ticket),
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

  def handle_call({:attempt_complete, loop_id, payload, daemon_name}, _from, state) do
    case handle_attempt_completion(loop_id, payload, daemon_name, state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_task_loop, loop_id, daemon_name, opts}, _from, state) do
    case start_task_loop_internal(loop_id, daemon_name, opts, state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_loop_history, loop_id}, _from, state) do
    history = Map.get(state.task_history, loop_id, [])
    {:reply, history, state}
  end

  def handle_call({:current_step_terminal_id, loop_id}, _from, state) do
    history = Map.get(state.task_history, loop_id, [])
    {:reply, history |> current_running_history_entry() |> maybe_history_entry_id(), state}
  end

  def handle_call({:latest_step_terminal_id, loop_id}, _from, state) do
    history = Map.get(state.task_history, loop_id, [])
    {:reply, history |> latest_history_entry() |> maybe_history_entry_id(), state}
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

  defp start_task_loop_internal(loop_id, daemon_name, opts, state) do
    with %{} = loop <- Loops.get_loop(loop_id),
         true <- loop.role == :task,
         {:ok, daemon} <- fetch_daemon(daemon_name),
         :ok <- check_repo_ready(daemon.name, loop),
         {:ok, loop} <-
           Loops.update_loop(loop, %{
             status: :running_maker,
             assigned_daemon_id: daemon.id,
             current_attempt: max(loop.current_attempt, 0) + 1
           }) do
      loop = Repo.preload(loop, dag: :ticket)
      task = maker_task(loop, loop.dag.ticket, "")
      run_opts = task_run_options(opts, loop.dag.ticket)

      state
      |> put_task_run_config(loop.id, run_opts)
      |> append_history(loop.id, history_entry("maker", loop.current_attempt, "running"))
      |> push_to_daemon(
        daemon.name,
        loop.id,
        Map.merge(%{"role" => "maker", "task" => task}, run_opts)
      )
      |> then(&{:ok, &1})
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_task_loop}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_attempt_completion(loop_id, payload, daemon_name, state) do
    case Ecto.UUID.cast(loop_id) do
      :error ->
        {:ok, state}

      {:ok, _} ->
        case Loops.get_loop(loop_id) do
          nil ->
            {:ok, state}

          %{role: :task} = loop ->
            process_task_attempt(loop, payload, daemon_name, state)

          %{role: :decompose_checker} = loop ->
            _ = loop
            _ = payload
            {:ok, state}

          _ ->
            {:ok, state}
        end
    end
  end

  defp process_task_attempt(loop, payload, daemon_name, state) do
    loop = Repo.preload(loop, dag: :ticket)
    session_id = Map.get(payload, "session_id")
    exit_code = Map.get(payload, "exit_code", 0)

    case loop.status do
      :running_maker ->
        process_maker_attempt(loop, daemon_name, session_id, exit_code, state)

      :running_checker ->
        process_checker_attempt(loop, payload, daemon_name, session_id, exit_code, state)

      _ ->
        {:ok, state}
    end
  end

  defp process_maker_attempt(loop, daemon_name, session_id, exit_code, state) do
    ticket = loop.dag.ticket

    with {:ok, daemon} <- ensure_daemon(loop, daemon_name),
         {:ok, loop} <- Loops.update_loop_status(loop, :running_checker) do
      checker_task = checker_task(loop, ticket)

      state =
        state
        |> complete_last_history(loop.id, "maker", loop.current_attempt,
          session_id: session_id,
          exit_code: exit_code,
          status: "completed"
        )
        |> append_history(loop.id, history_entry("checker", loop.current_attempt, "running"))
        |> push_to_daemon(
          daemon.name,
          loop.id,
          Map.merge(
            %{
              "role" => "checker",
              "task" => checker_task,
              "attempt" => loop.current_attempt
            },
            task_run_config(state, loop.id)
          )
        )

      {:ok, state}
    else
      _ -> {:error, :transition_failed}
    end
  end

  defp process_checker_attempt(loop, payload, daemon_name, session_id, exit_code, state) do
    ticket = loop.dag.ticket

    case CheckerHandoff.validate(loop.id, loop.current_attempt, payload) do
      {:ok, verified} ->
        verdict = parse_checker_verdict(verified)
        feedback = parse_checker_feedback(verified)
        feedback_path = Map.get(verified, :feedback_path)

        state =
          state
          |> clear_checker_handoff_repair(loop.id)
          |> complete_last_history(loop.id, "checker", loop.current_attempt,
            session_id: session_id,
            exit_code: exit_code,
            verdict: verdict,
            feedback: feedback,
            feedback_path: feedback_path,
            status: "completed"
          )

        finalize_checker_attempt(verdict, loop, feedback, daemon_name, state)

      {:error, handoff_error} ->
        repair_checker_handoff(loop, ticket, daemon_name, handoff_error, session_id, state)
    end
  end

  defp retry_task_loop(loop, feedback, daemon_name, state) do
    if loop.current_attempt >= loop.max_attempts do
      case Loops.update_loop_status(loop, :failed) do
        {:ok, _} -> {:ok, clear_task_run_config(state, loop.id)}
        _ -> {:error, :update_failed}
      end
    else
      with {:ok, daemon} <- ensure_daemon(loop, daemon_name),
           {:ok, loop} <-
             Loops.update_loop(loop, %{
               status: :running_maker,
               current_attempt: loop.current_attempt + 1
             }) do
        loop = Repo.preload(loop, dag: :ticket)
        maker_prompt = maker_task(loop, loop.dag.ticket, feedback)

        state =
          state
          |> append_history(loop.id, history_entry("maker", loop.current_attempt, "running"))
          |> push_to_daemon(
            daemon.name,
            loop.id,
            Map.merge(
              %{"role" => "maker", "task" => maker_prompt},
              task_run_config(state, loop.id)
            )
          )

        {:ok, state}
      else
        _ -> {:error, :retry_failed}
      end
    end
  end

  defp finalize_checker_attempt("pass", loop, _feedback, _daemon_name, state) do
    case Loops.update_loop_status(loop, :passed) do
      {:ok, updated_loop} ->
        maybe_complete_ticket(updated_loop)
        {:ok, clear_task_run_config(state, loop.id)}

      _ ->
        {:error, :update_failed}
    end
  end

  defp finalize_checker_attempt(_verdict, loop, feedback, daemon_name, state) do
    retry_task_loop(loop, feedback, daemon_name, state)
  end

  defp ensure_daemon(loop, daemon_name) do
    cond do
      daemon_name ->
        fetch_daemon(daemon_name)

      loop.assigned_daemon_id ->
        {:ok, Daemons.get_daemon!(loop.assigned_daemon_id)}

      true ->
        find_online_daemon()
    end
  end

  defp fetch_daemon(daemon_name) do
    case Daemons.get_daemon_by_name(daemon_name) do
      nil -> {:error, :daemon_not_found}
      daemon -> {:ok, daemon}
    end
  end

  defp maybe_complete_ticket(loop) do
    all_loops =
      loop.dag_id
      |> Dags.list_loops_for_dag()
      |> Enum.map(& &1.status)

    if Enum.all?(all_loops, &(&1 == :passed)) do
      ticket = Tickets.get_ticket!(loop.dag.ticket_id)
      _ = Tickets.update_ticket(ticket, %{status: :completed})
    end
  end

  defp maker_task(loop, ticket, feedback) do
    task_desc = loop.description || loop.title
    ticket_ref = ticket_reference(ticket)
    plan_lookup = "ag ticket comments #{ticket_ref} --json"

    inline_reviews =
      loop.id
      |> InlineReviews.list_pending_by_loop()
      |> InlineReviews.serialize_for_prompt()

    sections = [
      "Ticket: #{ticket.title}",
      optional_section("Acceptance criteria", ticket.acceptance_criteria),
      format_comments(Tickets.list_comments(ticket.id)),
      """
      Fetch approved planning notes before implementation:
      #{plan_lookup}
      """,
      "Task:\n#{task_desc}",
      optional_section("Rubric", loop.rubric || ticket.rubric),
      optional_section("Previous checker feedback", non_empty(feedback)),
      inline_reviews,
      "Implement the task and run relevant checks before finishing."
    ]

    sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
  end

  defp checker_task(loop, ticket) do
    expected = CheckerHandoff.expected_paths(loop.id, loop.current_attempt)
    task_desc = loop.description || loop.title

    sections = [
      "Ticket: #{ticket.title}",
      optional_section("Acceptance criteria", ticket.acceptance_criteria),
      "Task:\n#{task_desc}",
      optional_section("Rubric", loop.rubric || ticket.rubric),
      """
      REQUIRED HANDOFF FORMAT (file IPC):
      1) Write markdown feedback to: #{expected.feedback}
      2) Write JSON to: #{expected.json}

      JSON must be exactly:
      {"VERDICT":"pass|fail","FEEDBACK":"#{expected.feedback}"}

      Rules:
      - Create parent directories if they do not exist.
      - VERDICT must be either "pass" or "fail" (lowercase).
      - FEEDBACK must be the markdown file path above.
      - Do not output any alternative verdict format.\
      """
    ]

    sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
  end

  defp optional_section(_label, nil), do: nil
  defp optional_section(_label, ""), do: nil
  defp optional_section(label, content), do: "#{label}:\n#{content}"

  defp non_empty(""), do: nil
  defp non_empty(nil), do: nil
  defp non_empty(s), do: s

  defp non_empty_list([]), do: nil
  defp non_empty_list(list), do: list

  defp parse_checker_verdict(%{verdict: verdict}) do
    case verdict do
      "pass" -> "pass"
      "fail" -> "fail"
      _ -> "fail"
    end
  end

  defp parse_checker_feedback(%{feedback: feedback}), do: feedback

  defp repair_checker_handoff(loop, _ticket, daemon_name, handoff_error, session_id, state) do
    repairs = Map.get(state.checker_handoff_repairs, loop.id, 0) + 1

    if repairs > @max_checker_handoff_repairs do
      state =
        state
        |> clear_checker_handoff_repair(loop.id)
        |> complete_last_history(loop.id, "checker", loop.current_attempt,
          session_id: session_id,
          verdict: "fail",
          feedback: "Invalid checker handoff: #{handoff_error}",
          status: "handoff_invalid"
        )

      retry_task_loop(loop, "Checker handoff invalid: #{handoff_error}", daemon_name, state)
    else
      case ensure_daemon(loop, daemon_name) do
        {:ok, daemon} ->
          repair_task = checker_handoff_repair_task(loop, handoff_error, repairs)

          state =
            state
            |> put_checker_handoff_repair(loop.id, repairs)
            |> push_to_daemon(
              daemon.name,
              loop.id,
              Map.merge(
                %{
                  "role" => "checker",
                  "task" => repair_task,
                  "attempt" => loop.current_attempt
                },
                task_run_config(state, loop.id)
              )
            )

          {:ok, state}

        _ ->
          state =
            state
            |> clear_checker_handoff_repair(loop.id)
            |> complete_last_history(loop.id, "checker", loop.current_attempt,
              session_id: session_id,
              verdict: "fail",
              feedback: "Invalid checker handoff: #{handoff_error}",
              status: "handoff_invalid"
            )

          {:ok, state}
      end
    end
  end

  defp checker_handoff_repair_task(loop, handoff_error, repairs) do
    expected = CheckerHandoff.expected_paths(loop.id, loop.current_attempt)

    """
    Handoff verifier failed for checker loop #{loop.id} (repair round #{repairs}):
    #{handoff_error}

    REPAIR-ONLY MODE:
    - Do NOT rerun checks.
    - Do NOT re-evaluate the codebase.
    - Use your previous checker conclusion and feedback from this attempt.
    - Only fix the handoff file contract.

    REQUIRED HANDOFF FORMAT (file IPC):
    1) Write markdown feedback to: #{expected.feedback}
    2) Write JSON to: #{expected.json}
    JSON exactly: {"VERDICT":"pass|fail","FEEDBACK":"#{expected.feedback}"}

    Rules:
    - Create parent directories if missing.
    - VERDICT must be lowercase pass/fail.
    - FEEDBACK must match the exact markdown path above.
    """
  end

  defp put_checker_handoff_repair(state, loop_id, count) do
    %{state | checker_handoff_repairs: Map.put(state.checker_handoff_repairs, loop_id, count)}
  end

  defp clear_checker_handoff_repair(state, loop_id) do
    %{state | checker_handoff_repairs: Map.delete(state.checker_handoff_repairs, loop_id)}
  end

  defp put_task_run_config(state, loop_id, config) do
    %{state | task_run_config: Map.put(state.task_run_config, loop_id, config)}
  end

  defp clear_task_run_config(state, loop_id) do
    %{state | task_run_config: Map.delete(state.task_run_config, loop_id)}
  end

  defp task_run_config(state, loop_id) do
    Map.get(state.task_run_config, loop_id, %{})
  end

  defp task_run_options(opts, ticket) do
    %{}
    |> maybe_put_opt("model", Keyword.get(opts, :model))
    |> maybe_put_opt("effort", Keyword.get(opts, :effort))
    |> maybe_put_opt("agent_type", Keyword.get(opts, :agent_type) || ticket_agent_type(ticket))
  end

  defp maybe_put_opt(map, _key, nil), do: map
  defp maybe_put_opt(map, key, value), do: Map.put(map, key, value)

  defp history_entry(role, attempt, status) do
    %{
      id: Ecto.UUID.generate(),
      role: role,
      attempt: attempt,
      status: status,
      started_at: DateTime.utc_now()
    }
  end

  defp current_running_history_entry(history) do
    history
    |> Enum.reverse()
    |> Enum.find(&(&1.status == "running"))
  end

  defp latest_history_entry(history), do: List.last(history)

  defp maybe_history_entry_id(nil), do: nil
  defp maybe_history_entry_id(entry), do: Map.get(entry, :id)

  defp append_history(state, loop_id, entry) do
    updated = Map.update(state.task_history, loop_id, [entry], fn h -> h ++ [entry] end)
    state = %{state | task_history: updated}
    broadcast_history(loop_id, updated[loop_id])
    state
  end

  defp complete_last_history(state, loop_id, role, attempt, attrs) do
    history = Map.get(state.task_history, loop_id, [])

    updated =
      history
      |> Enum.reverse()
      |> Enum.map(fn entry ->
        if entry.role == role && entry.attempt == attempt && entry.status == "running" do
          Map.merge(entry, attrs |> Map.new() |> Map.put(:finished_at, DateTime.utc_now()))
        else
          entry
        end
      end)
      |> Enum.reverse()

    task_history = Map.put(state.task_history, loop_id, updated)
    state = %{state | task_history: task_history}
    broadcast_history(loop_id, updated)
    state
  end

  defp broadcast_history(loop_id, history) do
    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      "loop:#{loop_id}",
      {:loop_history_updated, history}
    )
  end

  defp push_to_daemon(state, daemon_name, loop_id, opts) do
    state.push_fn.(daemon_name, loop_id, opts)
    state
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

      ticket = Tickets.get_ticket!(ticket_id)

      push_fn.(decomp.daemon_name, checker_loop.id, %{
        "role" => "decompose_checker",
        "agent_type" => ticket_agent_type(ticket),
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
          status: :planning
      }

      state = put_in(state, [:decompositions, ticket_id], decomp)
      push_fn = state.push_fn

      ticket = Tickets.get_ticket!(ticket_id)

      push_fn.(decomp.daemon_name, loop.id, %{
        "role" => "decompose",
        "agent_type" => ticket_agent_type(ticket),
        "ticket_id" => ticket_id,
        "ticket" => ticket_context(ticket),
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
    Tickets.update_ticket(ticket, %{status: :halted})
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

  defp check_repo_ready(daemon_name, loop) do
    loop = Repo.preload(loop, dag: [ticket: :workspace])
    workspace = loop.dag.ticket.workspace

    if workspace && workspace.github_repo_url do
      if Daemons.repo_ready?(daemon_name), do: :ok, else: {:error, :repo_not_ready}
    else
      :ok
    end
  end

  defp find_online_daemon, do: Daemons.find_online()

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
    comments = Tickets.list_comments(ticket.id)

    %{
      "title" => ticket.title,
      "description" => ticket.description,
      "acceptance_criteria" => ticket.acceptance_criteria,
      "rubric" => ticket.rubric,
      "type" => to_string(ticket.type),
      "priority" => ticket.priority,
      "comments" => non_empty_list(format_comments_data(comments))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp format_comments([]), do: nil

  defp format_comments(comments) do
    formatted =
      comments
      |> Enum.map_join("\n", &format_comment(&1, 0))

    """
    Ticket comments:
    #{formatted}

    """
  end

  defp format_comment(comment, depth) do
    indent = String.duplicate("  ", depth)
    header = "#{indent}- [#{comment.author}] #{comment.body}"

    replies =
      case comment.replies do
        %Ecto.Association.NotLoaded{} -> ""
        [] -> ""
        replies -> "\n" <> Enum.map_join(replies, "\n", &format_comment(&1, depth + 1))
      end

    header <> replies
  end

  defp format_comments_data([]), do: []

  defp format_comments_data(comments) do
    Enum.map(comments, &comment_to_map/1)
  end

  defp comment_to_map(comment) do
    replies =
      case comment.replies do
        %Ecto.Association.NotLoaded{} -> []
        replies -> Enum.map(replies, &comment_to_map/1)
      end

    %{
      "author" => comment.author,
      "body" => comment.body,
      "replies" => replies
    }
  end

  defp ticket_agent_type(ticket), do: Agents.ticket_agent_type(ticket)

  defp ticket_reference(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  defp ticket_reference(%{id: id}), do: id

  defp find_decomposition_by_loop(state, loop_id) do
    Enum.find_value(state.decompositions, fn {ticket_id, decomp} ->
      if decomp.loop_id == loop_id, do: {ticket_id, decomp}
    end)
  end

  defp default_push(daemon_name, loop_id, opts) do
    AlgedoniaWeb.DaemonChannel.push_start_loop(daemon_name, loop_id, opts)
  end
end
