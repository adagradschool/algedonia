defmodule Algedonia.TaskLoopOrchestrator do
  @moduledoc "GenServer managing the task loop lifecycle: maker → checker → retry/pass."
  use GenServer

  alias Algedonia.{Agents, CheckerHandoff, Daemons, Dags, Loops, PromptBuilder, Tickets}
  alias Algedonia.TaskLoopHistory, as: H

  @max_handoff_repairs 2

  @doc "Starts the TaskLoopOrchestrator GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {push_fn, opts} = Keyword.pop(opts, :push_fn, &default_push/3)

    GenServer.start_link(
      __MODULE__,
      %{push_fn: push_fn},
      Keyword.put_new(opts, :name, __MODULE__)
    )
  end

  @doc "Starts a task loop maker run."
  @spec start_task_loop(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def start_task_loop(loop_id, daemon_name, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      {:start_task_loop, loop_id, daemon_name, opts}
    )
  end

  @doc "Handles an attempt completion from the daemon."
  @spec handle_attempt_complete(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_attempt_complete(loop_id, payload, opts \\ []) do
    call_if_alive(
      opts,
      {:attempt_complete, loop_id, payload, Keyword.get(opts, :daemon_name)},
      {:error, :orchestrator_not_running}
    )
  end

  @doc "Handles an attempt error from the daemon."
  @spec handle_attempt_error(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_attempt_error(loop_id, payload, opts \\ []) do
    call_if_alive(
      opts,
      {:attempt_error, loop_id, payload, Keyword.get(opts, :daemon_name)},
      {:error, :orchestrator_not_running}
    )
  end

  @doc "Returns in-memory history for a loop's maker/checker spin-ups."
  @spec get_loop_history(binary(), keyword()) :: [map()]
  def get_loop_history(lid, opts \\ []), do: call_if_alive(opts, {:get_loop_history, lid}, [])

  @doc "Returns the currently running step terminal id for a loop."
  @spec current_step_terminal_id(binary(), keyword()) :: binary() | nil
  def current_step_terminal_id(lid, opts \\ []),
    do: call_if_alive(opts, {:current_step_terminal_id, lid}, nil)

  @doc "Returns the latest step terminal id for a loop."
  @spec latest_step_terminal_id(binary(), keyword()) :: binary() | nil
  def latest_step_terminal_id(lid, opts \\ []),
    do: call_if_alive(opts, {:latest_step_terminal_id, lid}, nil)

  defp call_if_alive(opts, msg, default) do
    case GenServer.whereis(Keyword.get(opts, :name, __MODULE__)) do
      nil -> default
      pid -> GenServer.call(pid, msg)
    end
  end

  @impl true
  def init(s) do
    Tickets.subscribe()
    {:ok, Map.merge(s, %{task_history: %{}, checker_handoff_repairs: %{}, task_run_config: %{}})}
  end

  @impl true
  def handle_call({:start_task_loop, lid, dn, opts}, _from, st) do
    case start_loop(lid, dn, opts, st) do
      {:ok, s} -> {:reply, :ok, s}
      {:error, r} -> {:reply, {:error, r}, st}
    end
  end

  def handle_call({:attempt_complete, lid, payload, dn}, _from, st) do
    case handle_completion(lid, payload, dn, st) do
      {:ok, s} -> {:reply, :ok, s}
      {:error, r} -> {:reply, {:error, r}, st}
    end
  end

  def handle_call({:attempt_error, lid, payload, dn}, _from, st) do
    case handle_error(lid, payload, dn, st) do
      {:ok, s} -> {:reply, :ok, s}
      {:error, r} -> {:reply, {:error, r}, st}
    end
  end

  def handle_call({:get_loop_history, lid}, _from, st),
    do: {:reply, Map.get(st.task_history, lid, []), st}

  def handle_call({:current_step_terminal_id, lid}, _from, st),
    do: {:reply, H.current_running_id(st, lid), st}

  def handle_call({:latest_step_terminal_id, lid}, _from, st),
    do: {:reply, H.latest_id(st, lid), st}

  @impl true
  def handle_info({:ticket_updated, %{status: :halted} = ticket}, state) do
    {:noreply, halt_running_loops(ticket, state)}
  end

  def handle_info({:ticket_updated, %{status: :planning} = ticket}, state) do
    {:noreply, auto_start_planning_loop(ticket, state)}
  end

  def handle_info({:ticket_updated, _ticket}, state), do: {:noreply, state}
  def handle_info({:ticket_created, _ticket}, state), do: {:noreply, state}
  def handle_info({:ticket_deleted, _ticket}, state), do: {:noreply, state}

  defp halt_running_loops(ticket, state) do
    loops = running_loops_for_ticket(ticket.id)

    Enum.reduce(loops, state, fn loop, acc ->
      AlgedoniaWeb.DaemonChannel.push_stop_loop(
        daemon_name_for(loop),
        loop.id,
        "ticket halted"
      )

      {:ok, _} = Loops.update_loop_status(loop, :failed)
      acc
    end)
  end

  defp auto_start_planning_loop(ticket, state) do
    case {Dags.get_dag_by_ticket(ticket.id), Daemons.find_online()} do
      {%{loops: loops}, {:ok, daemon}} ->
        case Enum.find(loops, &(&1.role == :task)) do
          nil ->
            state

          loop ->
            case start_loop(loop.id, daemon.name, [], state) do
              {:ok, new_state} -> new_state
              {:error, _} -> state
            end
        end

      _ ->
        state
    end
  end

  defp running_loops_for_ticket(ticket_id) do
    case Dags.get_dag_by_ticket(ticket_id) do
      %{loops: loops} ->
        Enum.filter(loops, &(&1.status in [:running_maker, :running_checker]))

      _ ->
        []
    end
  end

  defp daemon_name_for(%{assigned_daemon_id: id}) when not is_nil(id) do
    Daemons.get_daemon!(id).name
  end

  defp daemon_name_for(_), do: "unknown"

  defp start_loop(loop_id, daemon_name, opts, state) do
    with %{role: :task} = loop <- Loops.get_loop(loop_id) || {:error, :not_found},
         :ok <- guard_startable(loop),
         {:ok, daemon} <- fetch_daemon(daemon_name),
         :ok <- check_repo_ready(daemon.name, loop),
         {:ok, loop} <-
           Loops.update_loop(loop, %{
             status: :running_maker,
             assigned_daemon_id: daemon.id,
             current_attempt: max(loop.current_attempt, 0) + 1
           }) do
      loop = Loops.preload_with_ticket(loop)
      task = PromptBuilder.maker_task(loop, loop.dag.ticket, "")
      run = task_run_options(opts, loop.dag.ticket)

      {:ok,
       state
       |> put_rc(loop.id, run)
       |> H.append(loop.id, H.new_entry("maker", loop.current_attempt, "running"))
       |> push(daemon.name, loop.id, Map.merge(%{"role" => "maker", "task" => task}, run))}
    else
      %{role: _} -> {:error, :not_task_loop}
      {:error, r} -> {:error, r}
    end
  end

  defp handle_completion(loop_id, payload, daemon_name, state) do
    with {:ok, _} <- Ecto.UUID.cast(loop_id),
         %{role: :task} = loop <- Loops.get_loop(loop_id) do
      loop = Loops.preload_with_ticket(loop)
      sid = Map.get(payload, "session_id")
      ec = Map.get(payload, "exit_code", 0)

      case loop.status do
        :running_maker -> maker_done(loop, daemon_name, sid, ec, state)
        :running_checker -> checker_done(loop, payload, daemon_name, sid, ec, state)
        _ -> {:ok, state}
      end
    else
      # credo:disable-for-next-line Credo.Check.Design.TagTODO
      # TODO: implement decompose_checker attempt handling
      %{role: :decompose_checker} -> {:ok, state}
      _ -> {:ok, state}
    end
  end

  defp handle_error(loop_id, payload, daemon_name, state) do
    with {:ok, _} <- Ecto.UUID.cast(loop_id),
         %{role: :task} = loop <- Loops.get_loop(loop_id) do
      loop = Loops.preload_with_ticket(loop)
      sid = Map.get(payload, "session_id")
      ec = Map.get(payload, "exit_code", 1)
      message = Map.get(payload, "message", "agent exited with code #{ec}")

      case loop.status do
        :running_maker ->
          attrs = [session_id: sid, exit_code: ec, status: "failed", error: message]
          state = H.complete_last(state, loop.id, "maker", loop.current_attempt, attrs)
          do_retry(loop, "Maker run failed: #{message}", daemon_name, state)

        :running_checker ->
          attrs = [
            session_id: sid,
            exit_code: ec,
            verdict: "fail",
            feedback: "Checker run failed: #{message}",
            status: "failed",
            error: message
          ]

          state =
            state
            |> clear_hr(loop.id)
            |> H.complete_last(loop.id, "checker", loop.current_attempt, attrs)

          do_retry(loop, "Checker run failed: #{message}", daemon_name, state)

        _ ->
          {:ok, state}
      end
    else
      _ -> {:ok, state}
    end
  end

  defp maker_done(loop, dn, sid, ec, state) do
    with {:ok, daemon} <- ensure_daemon(loop, dn),
         {:ok, loop} <- Loops.update_loop_status(loop, :running_checker) do
      ct = PromptBuilder.checker_task(loop, loop.dag.ticket)
      att = loop.current_attempt
      p = Map.merge(%{"role" => "checker", "task" => ct, "attempt" => att}, rc(state, loop.id))
      done_attrs = [session_id: sid, exit_code: ec, status: "completed"]

      {:ok,
       state
       |> H.complete_last(loop.id, "maker", att, done_attrs)
       |> H.append(loop.id, H.new_entry("checker", att, "running"))
       |> push(daemon.name, loop.id, p)}
    else
      _ -> {:error, :transition_failed}
    end
  end

  defp checker_done(loop, payload, dn, sid, ec, state) do
    case CheckerHandoff.validate(loop.id, loop.current_attempt, payload) do
      {:ok, v} ->
        verdict = if(v.verdict == "pass", do: "pass", else: "fail")
        fp = Map.get(v, :feedback_path)

        a = [
          session_id: sid,
          exit_code: ec,
          verdict: verdict,
          feedback: v.feedback,
          feedback_path: fp,
          status: "completed"
        ]

        state =
          state
          |> clear_hr(loop.id)
          |> H.complete_last(loop.id, "checker", loop.current_attempt, a)

        apply_verdict(verdict, loop, v.feedback, dn, state)

      {:error, err} ->
        repair_handoff(loop, dn, err, sid, state)
    end
  end

  defp apply_verdict("pass", loop, _feedback, _dn, state) do
    case Loops.update_loop_status(loop, :passed) do
      {:ok, ul} ->
        maybe_complete_ticket(ul)
        {:ok, clear_rc(state, loop.id)}

      _ ->
        {:error, :update_failed}
    end
  end

  defp apply_verdict(_fail, loop, feedback, dn, state), do: do_retry(loop, feedback, dn, state)

  defp do_retry(loop, feedback, dn, state) do
    if loop.current_attempt >= loop.max_attempts do
      case Loops.update_loop_status(loop, :failed) do
        {:ok, _} -> {:ok, clear_rc(state, loop.id)}
        _ -> {:error, :update_failed}
      end
    else
      with {:ok, daemon} <- ensure_daemon(loop, dn),
           {:ok, loop} <-
             Loops.update_loop(loop, %{
               status: :running_maker,
               current_attempt: loop.current_attempt + 1
             }) do
        loop = Loops.preload_with_ticket(loop)
        p = PromptBuilder.maker_task(loop, loop.dag.ticket, feedback)

        pl = Map.merge(%{"role" => "maker", "task" => p}, rc(state, loop.id))

        {:ok,
         state
         |> H.append(loop.id, H.new_entry("maker", loop.current_attempt, "running"))
         |> push(daemon.name, loop.id, pl)}
      else
        _ -> {:error, :retry_failed}
      end
    end
  end

  defp repair_handoff(loop, dn, err, sid, state) do
    repairs = Map.get(state.checker_handoff_repairs, loop.id, 0) + 1

    if repairs > @max_handoff_repairs do
      do_retry(loop, "Checker handoff invalid: #{err}", dn, fail_hr(state, loop, sid, err))
    else
      case ensure_daemon(loop, dn) do
        {:ok, daemon} ->
          task = PromptBuilder.checker_handoff_repair_task(loop, err, repairs)

          pl =
            Map.merge(
              %{"role" => "checker", "task" => task, "attempt" => loop.current_attempt},
              rc(state, loop.id)
            )

          {:ok, state |> put_hr(loop.id, repairs) |> push(daemon.name, loop.id, pl)}

        _ ->
          {:ok, fail_hr(state, loop, sid, err)}
      end
    end
  end

  defp fail_hr(state, loop, sid, err) do
    a = [
      session_id: sid,
      verdict: "fail",
      feedback: "Invalid checker handoff: #{err}",
      status: "handoff_invalid"
    ]

    state |> clear_hr(loop.id) |> H.complete_last(loop.id, "checker", loop.current_attempt, a)
  end

  defp maybe_complete_ticket(loop) do
    task_loops =
      loop.dag_id
      |> Dags.list_loops_for_dag()
      |> Enum.filter(&(&1.role == :task))

    all_tasks_passed? = task_loops != [] and Enum.all?(task_loops, &(&1.status == :passed))

    if all_tasks_passed? do
      Tickets.update_ticket(Tickets.get_ticket!(loop.dag.ticket_id), %{status: :completed})
    end
  end

  defp ensure_daemon(_loop, dn) when is_binary(dn), do: fetch_daemon(dn)

  defp ensure_daemon(%{assigned_daemon_id: id}, _) when not is_nil(id),
    do: {:ok, Daemons.get_daemon!(id)}

  defp ensure_daemon(_, _), do: Daemons.find_online()

  defp fetch_daemon(n),
    do: if(d = Daemons.get_daemon_by_name(n), do: {:ok, d}, else: {:error, :daemon_not_found})

  defp check_repo_ready(dn, loop) do
    ws = Loops.preload_with_workspace(loop).dag.ticket.workspace

    if ws && ws.github_repo_url && !Daemons.repo_ready?(dn),
      do: {:error, :repo_not_ready},
      else: :ok
  end

  defp push(state, dn, lid, opts) do
    state.push_fn.(dn, lid, opts)
    state
  end

  defp task_run_options(opts, ticket) do
    %{}
    |> mp("model", Keyword.get(opts, :model))
    |> mp("effort", Keyword.get(opts, :effort))
    |> mp("agent_type", Keyword.get(opts, :agent_type) || Agents.ticket_agent_type(ticket))
  end

  defp mp(m, _k, nil), do: m
  defp mp(m, k, v), do: Map.put(m, k, v)
  defp put_rc(s, id, c), do: %{s | task_run_config: Map.put(s.task_run_config, id, c)}
  defp clear_rc(s, id), do: %{s | task_run_config: Map.delete(s.task_run_config, id)}
  defp rc(s, id), do: Map.get(s.task_run_config, id, %{})

  defp put_hr(s, id, n),
    do: %{s | checker_handoff_repairs: Map.put(s.checker_handoff_repairs, id, n)}

  defp clear_hr(s, id),
    do: %{s | checker_handoff_repairs: Map.delete(s.checker_handoff_repairs, id)}

  defp guard_startable(%{status: status}) when status in [:pending, :ready], do: :ok
  defp guard_startable(_), do: {:error, :already_running}

  defp default_push(dn, lid, opts),
    do: AlgedoniaWeb.DaemonChannel.push_start_loop(dn, lid, opts)
end
