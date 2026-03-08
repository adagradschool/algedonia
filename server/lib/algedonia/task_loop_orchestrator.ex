defmodule Algedonia.TaskLoopOrchestrator do
  @moduledoc "GenServer managing the task loop lifecycle: maker → checker → retry/pass."
  use GenServer

  alias Algedonia.{
    Agents,
    CheckerHandoff,
    Daemons,
    Loops,
    PromptBuilder,
    Skills,
    TenantScope,
    Tickets,
    Workspaces
  }

  @max_handoff_repairs 2
  @default_base_pipeline [
    %{
      "step_id" => "base-just-lint-and-test",
      "skill" => "command",
      "params" => "just lint && just test",
      "required" => true
    }
  ]

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

  @doc """
  Starts a task loop maker run.

  Requires `:workspace_id` in opts.
  """
  @spec start_task_loop(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def start_task_loop(loop_id, daemon_name, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    case workspace_id do
      nil ->
        {:error, :workspace_scope_required}

      _ ->
        GenServer.call(
          Keyword.get(opts, :name, __MODULE__),
          {:start_task_loop, loop_id, daemon_name, opts}
        )
    end
  end

  @doc "Handles an attempt completion from the daemon."
  @spec handle_attempt_complete(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_attempt_complete(loop_id, payload, opts \\ []) do
    call_if_alive(
      opts,
      {:attempt_complete, loop_id, payload, Keyword.get(opts, :daemon_name),
       Keyword.get(opts, :workspace_id)},
      {:error, :orchestrator_not_running}
    )
  end

  @doc "Handles an attempt error from the daemon."
  @spec handle_attempt_error(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_attempt_error(loop_id, payload, opts \\ []) do
    call_if_alive(
      opts,
      {:attempt_error, loop_id, payload, Keyword.get(opts, :daemon_name),
       Keyword.get(opts, :workspace_id)},
      {:error, :orchestrator_not_running}
    )
  end

  @doc "Returns DB-persisted history for a loop's maker/checker steps."
  @spec get_loop_history(binary(), keyword()) :: [map()]
  def get_loop_history(lid, opts \\ []) do
    call_if_alive(opts, {:get_loop_history, lid, Keyword.get(opts, :workspace_id)}, [])
  end

  @doc "Returns the currently running step terminal id for a loop."
  @spec current_step_terminal_id(binary(), keyword()) :: binary() | nil
  def current_step_terminal_id(lid, opts \\ []),
    do:
      call_if_alive(opts, {:current_step_terminal_id, lid, Keyword.get(opts, :workspace_id)}, nil)

  @doc "Returns the latest step terminal id for a loop."
  @spec latest_step_terminal_id(binary(), keyword()) :: binary() | nil
  def latest_step_terminal_id(lid, opts \\ []),
    do:
      call_if_alive(opts, {:latest_step_terminal_id, lid, Keyword.get(opts, :workspace_id)}, nil)

  defp call_if_alive(opts, msg, default) do
    case GenServer.whereis(Keyword.get(opts, :name, __MODULE__)) do
      nil -> default
      pid -> GenServer.call(pid, msg)
    end
  end

  @impl true
  def init(s) do
    {:ok,
     Map.merge(s, %{
       checker_handoff_repairs: %{},
       task_run_config: %{},
       subscribed_ticket_workspaces: MapSet.new()
     })}
  end

  @impl true
  def handle_call({:start_task_loop, lid, dn, opts}, _from, st) do
    workspace_id = Keyword.get(opts, :workspace_id)
    st = ensure_ticket_workspace_subscription(st, workspace_id)

    case run_with_workspace(workspace_id, {:error, :workspace_scope_required}, fn ->
           start_loop(lid, dn, opts, workspace_id, st)
         end) do
      {:ok, s} -> {:reply, :ok, s}
      {:error, r} -> {:reply, {:error, r}, st}
    end
  end

  def handle_call({:attempt_complete, lid, payload, dn, workspace_id}, _from, st) do
    workspace_id = workspace_id_for_loop(st, lid, workspace_id)

    case run_with_workspace(workspace_id, {:error, :workspace_scope_required}, fn ->
           handle_completion(lid, payload, dn, st)
         end) do
      {:ok, s} -> {:reply, :ok, s}
      {:error, r} -> {:reply, {:error, r}, st}
    end
  end

  def handle_call({:attempt_error, lid, payload, dn, workspace_id}, _from, st) do
    workspace_id = workspace_id_for_loop(st, lid, workspace_id)

    case run_with_workspace(workspace_id, {:error, :workspace_scope_required}, fn ->
           handle_error(lid, payload, dn, st)
         end) do
      {:ok, s} -> {:reply, :ok, s}
      {:error, r} -> {:reply, {:error, r}, st}
    end
  end

  def handle_call({:get_loop_history, lid, workspace_id}, _from, st) do
    workspace_id = workspace_id_for_loop(st, lid, workspace_id)

    steps =
      run_with_workspace(workspace_id, [], fn ->
        lid
        |> Loops.list_steps_for_loop()
        |> Enum.map(&step_to_map/1)
      end)

    {:reply, steps, st}
  end

  def handle_call({:current_step_terminal_id, lid, workspace_id}, _from, st) do
    workspace_id = workspace_id_for_loop(st, lid, workspace_id)

    id =
      run_with_workspace(workspace_id, nil, fn ->
        case Loops.current_running_step(lid) do
          nil -> nil
          step -> step.id
        end
      end)

    {:reply, id, st}
  end

  def handle_call({:latest_step_terminal_id, lid, workspace_id}, _from, st) do
    workspace_id = workspace_id_for_loop(st, lid, workspace_id)

    id =
      run_with_workspace(workspace_id, nil, fn ->
        case Loops.latest_step(lid) do
          nil -> nil
          step -> step.id
        end
      end)

    {:reply, id, st}
  end

  @impl true
  def handle_info({:ticket_updated, %{status: :halted} = ticket}, state) do
    {:noreply,
     run_with_workspace(ticket.workspace_id, state, fn -> halt_running_loops(ticket, state) end)}
  end

  def handle_info({:ticket_updated, %{status: :in_progress} = ticket}, state) do
    {:noreply,
     run_with_workspace(ticket.workspace_id, state, fn ->
       auto_start_in_progress_loop(ticket, state)
     end)}
  end

  def handle_info({:ticket_updated, %{status: :in_review}}, state), do: {:noreply, state}

  def handle_info({:ticket_updated, %{status: :archived} = ticket}, state) do
    run_with_workspace(ticket.workspace_id, :ok, fn -> cleanup_ticket_worktree(ticket) end)
    {:noreply, state}
  end

  def handle_info({:ticket_updated, _ticket}, state), do: {:noreply, state}
  def handle_info({:ticket_created, _ticket}, state), do: {:noreply, state}
  def handle_info({:ticket_deleted, _ticket}, state), do: {:noreply, state}

  defp halt_running_loops(ticket, state) do
    loops = running_loops_for_ticket(ticket.id)

    Enum.reduce(loops, state, fn loop, acc ->
      if loop.role == :planning do
        acc
      else
        AlgedoniaWeb.DaemonChannel.push_stop_loop(
          daemon_name_for(loop),
          loop.id,
          "ticket halted"
        )

        {:ok, _} = Loops.update_loop_status(loop, :failed)
        acc
      end
    end)
  end

  defp auto_start_in_progress_loop(ticket, state) do
    with {:ok, daemon} <- Daemons.find_online(),
         %{id: loop_id} <- pending_task_loop_for_ticket(ticket.id),
         {:ok, new_state} <- start_loop(loop_id, daemon.name, [], ticket.workspace_id, state) do
      new_state
    else
      _ -> state
    end
  end

  defp pending_task_loop_for_ticket(ticket_id) do
    ticket_id
    |> Loops.list_task_loops_for_ticket()
    |> Enum.find(&(&1.status == :pending))
  end

  defp running_loops_for_ticket(ticket_id) do
    ticket_id
    |> Loops.list_loops_for_ticket()
    |> Enum.filter(&(&1.status == :running))
  end

  defp daemon_name_for(%{assigned_daemon_id: id}) when not is_nil(id) do
    Daemons.get_daemon!(id).name
  end

  defp daemon_name_for(_), do: "unknown"

  defp start_loop(loop_id, daemon_name, opts, workspace_id, state) do
    with %{role: :task} = loop <- Loops.get_loop(loop_id) || {:error, :not_found},
         true <- loop.workspace_id == workspace_id || {:error, :workspace_scope_mismatch},
         max_attempts <- loop_iteration_budget(loop),
         :ok <- guard_startable(loop, max_attempts),
         {:ok, daemon} <- fetch_daemon(daemon_name),
         :ok <- check_repo_ready(daemon.name, loop),
         {:ok, loop} <-
           Loops.update_loop(loop, %{
             status: :running,
             assigned_daemon_id: daemon.id,
             current_attempt: max(loop.current_attempt, 0) + 1,
             max_attempts: max_attempts
           }) do
      loop = Loops.preload_with_workspace(loop)
      task = PromptBuilder.maker_task(loop, loop.ticket, "")
      ws_slug = loop.ticket.workspace.slug
      ticket_id = loop.ticket.id

      run =
        task_run_options(opts, loop.ticket)
        |> mp("workspace_slug", ws_slug)
        |> mp("ticket_id", ticket_id)
        |> mp("workspace_id", workspace_id)

      {:ok, _step} =
        Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: loop.current_attempt,
          status: "running",
          started_at: DateTime.utc_now()
        })

      {:ok,
       state
       |> put_rc(loop.id, run)
       |> push(daemon.name, loop.id, Map.merge(%{"role" => "maker", "task" => task}, run))}
    else
      %{role: _} ->
        {:error, :not_task_loop}

      {:error, :attempts_exhausted} = err ->
        loop = Loops.get_loop(loop_id)
        if loop, do: Loops.update_loop_status(loop, :failed)
        err

      {:error, r} ->
        {:error, r}
    end
  end

  defp handle_completion(loop_id, payload, daemon_name, state) do
    with {:ok, _} <- Ecto.UUID.cast(loop_id),
         %{role: :task} = loop <- Loops.get_loop(loop_id) do
      loop = Loops.preload_with_workspace(loop)
      sid = Map.get(payload, "session_id")
      ec = Map.get(payload, "exit_code", 0)

      case completion_phase(loop.id, payload) do
        "maker" -> maker_done(loop, daemon_name, sid, ec, state)
        "checker" -> checker_done(loop, payload, daemon_name, sid, ec, state)
        _ -> {:ok, state}
      end
    else
      _ -> {:ok, state}
    end
  end

  defp handle_error(loop_id, payload, daemon_name, state) do
    with {:ok, _} <- Ecto.UUID.cast(loop_id),
         %{role: :task} = loop <- Loops.get_loop(loop_id) do
      loop = Loops.preload_with_workspace(loop)
      sid = Map.get(payload, "session_id")
      ec = Map.get(payload, "exit_code", 1)
      message = Map.get(payload, "message", "agent exited with code #{ec}")

      case completion_phase(loop.id, payload) do
        "maker" ->
          Loops.complete_last_running(loop.id, "maker", loop.current_attempt, %{
            session_id: sid,
            exit_code: ec,
            status: "failed",
            error: message
          })

          do_retry(loop, "Maker run failed: #{message}", daemon_name, state)

        "checker" ->
          Loops.complete_last_running(loop.id, "checker", loop.current_attempt, %{
            session_id: sid,
            exit_code: ec,
            verdict: "fail",
            feedback: "Checker run failed: #{message}",
            status: "failed",
            error: message
          })

          state = clear_hr(state, loop.id)
          do_retry(loop, "Checker run failed: #{message}", daemon_name, state)

        _ ->
          {:ok, state}
      end
    else
      _ -> {:ok, state}
    end
  end

  defp maker_done(loop, dn, sid, ec, state) do
    loop = Loops.preload_with_workspace(loop)
    ct = PromptBuilder.checker_task(loop, loop.ticket, ws_slug_for(loop))
    att = loop.current_attempt

    p =
      Map.merge(
        %{"role" => "checker", "task" => ct, "attempt" => att},
        scoped_run_context(state, loop)
      )

    Loops.complete_last_running(loop.id, "maker", att, %{
      session_id: sid,
      exit_code: ec,
      status: "completed"
    })

    case validate_loop_checker_config(loop) do
      :ok ->
        case dispatch_checker_transition(loop, dn, att, p, state) do
          {:ok, next_state} ->
            {:ok, next_state}

          {:error, reason} ->
            {:ok, fail_checker_transition(loop, att, reason, state)}
        end

      {:error, errors} ->
        {:ok, fail_checker_transition(loop, att, {:invalid_checker_config, errors}, state)}
    end
  end

  defp dispatch_checker_transition(loop, daemon_name, attempt, payload, state) do
    with {:ok, daemon} <- ensure_daemon(loop, daemon_name),
         {:ok, _step} <- create_checker_step(loop.id, attempt) do
      push_checker_payload(state, daemon.name, loop.id, payload)
    end
  end

  defp create_checker_step(loop_id, attempt) do
    Loops.create_step(%{
      loop_id: loop_id,
      role: "checker",
      attempt: attempt,
      status: "running",
      started_at: DateTime.utc_now()
    })
  end

  defp push_checker_payload(state, daemon_name, loop_id, payload) do
    {:ok, push(state, daemon_name, loop_id, payload)}
  rescue
    error -> {:error, error}
  end

  defp checker_done(loop, payload, dn, sid, ec, state) do
    case CheckerHandoff.validate(loop.id, loop.current_attempt, ws_slug_for(loop), payload) do
      {:ok, v} ->
        receipts = evaluate_checker_attempt(loop, payload, v)
        persist_checker_receipts(loop, receipts, sid, ec, Map.get(v, :feedback_path))
        state = clear_hr(state, loop.id)
        apply_checker_attempt_result(loop, receipts, dn, state)

      {:error, err} ->
        repair_handoff(loop, dn, err, sid, state)
    end
  end

  defp apply_checker_attempt_result(loop, receipts, dn, state) do
    case first_failed_required_receipt(receipts) do
      nil -> apply_verdict("pass", loop, nil, dn, state)
      receipt -> do_retry(loop, retry_feedback_text(receipt), dn, state, failed_receipt: receipt)
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

  defp do_retry(loop, feedback, dn, state, opts \\ []) do
    failed_receipt = Keyword.get(opts, :failed_receipt)
    max_attempts = loop_iteration_budget(loop)

    if loop.current_attempt >= max_attempts do
      case Loops.update_loop_status(loop, :failed) do
        {:ok, _updated} ->
          maybe_halt_ticket_after_checker_exhaustion(loop, failed_receipt)
          {:ok, clear_rc(state, loop.id)}

        _ ->
          {:error, :update_failed}
      end
    else
      with {:ok, daemon} <- ensure_daemon(loop, dn),
           {:ok, loop} <-
             Loops.update_loop(loop, %{
               status: :running,
               current_attempt: loop.current_attempt + 1,
               max_attempts: max_attempts
             }) do
        loop = Loops.preload_with_workspace(loop)
        p = PromptBuilder.maker_task(loop, loop.ticket, feedback)

        pl =
          Map.merge(%{"role" => "maker", "task" => p}, scoped_run_context(state, loop))
          |> maybe_put_failed_receipt(failed_receipt)

        {:ok, _step} =
          Loops.create_step(%{
            loop_id: loop.id,
            role: "maker",
            attempt: loop.current_attempt,
            status: "running",
            started_at: DateTime.utc_now()
          })

        {:ok, push(state, daemon.name, loop.id, pl)}
      else
        _ -> {:error, :retry_failed}
      end
    end
  end

  defp evaluate_checker_attempt(loop, payload, validated) do
    payload_receipts = payload_step_receipts(payload)

    {receipts, _global_fail_consumed?} =
      checker_step_plan(loop)
      |> Enum.reduce_while({[], false}, fn step, {acc, global_fail_consumed?} ->
        payload_receipt = find_payload_step_receipt(payload_receipts, step)

        {verdict, summary, global_fail_consumed?} =
          resolve_checker_step_result(step, payload_receipt, validated, global_fail_consumed?)

        receipt = %{
          step_id: step.step_id,
          skill: step.skill,
          order_index: step.order_index,
          required: step.required,
          verdict: verdict,
          summary: summary,
          attempt: loop.current_attempt
        }

        acc = [receipt | acc]

        if required_receipt_failure?(receipt),
          do: {:halt, {acc, global_fail_consumed?}},
          else: {:cont, {acc, global_fail_consumed?}}
      end)

    Enum.reverse(receipts)
  end

  defp persist_checker_receipts(loop, receipts, sid, ec, feedback_path) do
    now = DateTime.utc_now()

    Enum.with_index(receipts)
    |> Enum.each(fn {receipt, index} ->
      attrs =
        checker_receipt_attrs(receipt, sid, ec, if(index == 0, do: feedback_path, else: nil))

      if index == 0 do
        persist_first_checker_receipt(loop, attrs, now)
      else
        create_checker_receipt_step(loop, attrs, now, index)
      end
    end)
  end

  defp checker_receipt_attrs(receipt, sid, ec, feedback_path) do
    %{
      session_id: sid,
      exit_code: ec,
      status: receipt_status(receipt.verdict),
      verdict: receipt.verdict,
      summary: receipt.summary,
      feedback: receipt.summary,
      feedback_path: feedback_path,
      step_id: receipt.step_id,
      skill: receipt.skill,
      order_index: receipt.order_index,
      required: receipt.required
    }
  end

  defp persist_first_checker_receipt(loop, attrs, now) do
    case Loops.complete_last_running(loop.id, "checker", loop.current_attempt, attrs) do
      {:ok, _step} ->
        :ok

      :not_found ->
        _ =
          Loops.create_step(
            Map.merge(attrs, %{
              loop_id: loop.id,
              role: "checker",
              attempt: loop.current_attempt,
              started_at: now,
              finished_at: DateTime.add(now, 1, :microsecond)
            })
          )

        :ok
    end
  end

  defp create_checker_receipt_step(loop, attrs, now, index) do
    _ =
      Loops.create_step(
        Map.merge(attrs, %{
          loop_id: loop.id,
          role: "checker",
          attempt: loop.current_attempt,
          started_at: DateTime.add(now, index, :microsecond),
          finished_at: DateTime.add(now, index + 1, :microsecond)
        })
      )

    :ok
  end

  defp checker_step_plan(loop) do
    config = Map.get(loop, :checker_config)

    base_steps =
      config_steps(config, [:base, :base_pipeline, :base_steps])
      |> default_if_empty(@default_base_pipeline)

    ticket_steps =
      if is_list(config),
        do: config,
        else:
          config_steps(config, [
            :ticket_specific,
            :ticket_specific_steps,
            :approved_checker_config,
            :steps
          ])

    (base_steps ++ ticket_steps)
    |> Enum.with_index()
    |> Enum.map(fn {step, order_index} -> normalize_checker_step(step, order_index) end)
  end

  defp config_steps(config, keys) when is_map(config) and is_list(keys) do
    Enum.find_value(keys, [], fn key ->
      case map_value(config, key) do
        steps when is_list(steps) -> steps
        _ -> nil
      end
    end)
  end

  defp config_steps(_config, _keys), do: []

  defp default_if_empty([], default), do: default
  defp default_if_empty(list, _default), do: list

  defp normalize_checker_step(step, order_index) when is_binary(step) do
    %{
      step_id: "checker-step-#{order_index}",
      skill: "command",
      order_index: order_index,
      required: true
    }
    |> maybe_put_step_params(step)
  end

  defp normalize_checker_step(step, order_index) when is_map(step) do
    required = map_value(step, :required)

    %{
      step_id: normalize_step_id(map_value(step, :step_id), order_index),
      skill: normalize_skill(map_value(step, :skill)),
      order_index: order_index,
      required: if(is_boolean(required), do: required, else: true)
    }
    |> maybe_put_step_params(map_value(step, :params))
  end

  defp normalize_checker_step(_step, order_index),
    do: %{
      step_id: "checker-step-#{order_index}",
      skill: "command",
      order_index: order_index,
      required: true
    }

  defp maybe_put_step_params(step, params) when is_nil(params), do: step
  defp maybe_put_step_params(step, params), do: Map.put(step, :params, params)

  defp normalize_step_id(nil, order_index), do: "checker-step-#{order_index}"
  defp normalize_step_id("", order_index), do: "checker-step-#{order_index}"
  defp normalize_step_id(step_id, _order_index), do: to_string(step_id) |> String.trim()

  defp normalize_skill(nil), do: "command"
  defp normalize_skill(""), do: "command"
  defp normalize_skill(skill), do: to_string(skill) |> String.trim()

  defp payload_step_receipts(payload) do
    case map_value(payload, :checker_step_receipts) || map_value(payload, :step_receipts) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp find_payload_step_receipt(receipts, step) do
    Enum.find(receipts, fn receipt ->
      receipt_step_id = map_value(receipt, :step_id)
      receipt_order_index = normalize_order_index(map_value(receipt, :order_index))

      (is_binary(receipt_step_id) && String.trim(receipt_step_id) == step.step_id) ||
        receipt_order_index == step.order_index
    end)
  end

  defp resolve_checker_step_result(_step, payload_receipt, validated, global_fail_consumed?)
       when is_map(payload_receipt) do
    verdict =
      map_value(payload_receipt, :verdict)
      |> normalize_receipt_verdict()

    summary =
      map_value(payload_receipt, :summary) ||
        map_value(payload_receipt, :feedback) ||
        validated.feedback

    {verdict, normalize_summary(summary), global_fail_consumed?}
  end

  defp resolve_checker_step_result(step, _payload_receipt, validated, global_fail_consumed?) do
    if validated.verdict == "pass" do
      {"pass", normalize_summary(validated.feedback), global_fail_consumed?}
    else
      if step.required && !global_fail_consumed? do
        {"fail", normalize_summary(validated.feedback), true}
      else
        {"pass", "Passed before failing required step.", global_fail_consumed?}
      end
    end
  end

  defp normalize_receipt_verdict(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "fail"
      verdict -> verdict
    end
  end

  defp normalize_summary(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "No summary provided."
      summary -> summary
    end
  end

  defp normalize_order_index(nil), do: nil
  defp normalize_order_index(i) when is_integer(i), do: i

  defp normalize_order_index(value) do
    case Integer.parse(to_string(value)) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp receipt_status(verdict) when verdict in ["pass", "fail"], do: "completed"
  defp receipt_status(_), do: "failed"

  defp required_receipt_failure?(receipt), do: receipt.required && receipt.verdict != "pass"

  defp first_failed_required_receipt(receipts),
    do: Enum.find(receipts, &required_receipt_failure?/1)

  defp retry_feedback_text(receipt) do
    """
    Checker required step failed.
    step_id: #{receipt.step_id}
    skill: #{receipt.skill}
    verdict: #{receipt.verdict}
    summary: #{receipt.summary}
    """
  end

  defp maybe_put_failed_receipt(payload, nil), do: payload

  defp maybe_put_failed_receipt(payload, receipt),
    do: Map.put(payload, "checker_failure", failed_receipt_payload(receipt))

  defp failed_receipt_payload(receipt) do
    %{
      "step_id" => receipt.step_id,
      "skill" => receipt.skill,
      "order_index" => receipt.order_index,
      "required" => receipt.required,
      "verdict" => receipt.verdict,
      "summary" => receipt.summary,
      "attempt" => receipt.attempt
    }
  end

  defp maybe_halt_ticket_after_checker_exhaustion(_loop, nil), do: :ok

  defp maybe_halt_ticket_after_checker_exhaustion(loop, _failed_receipt) do
    ticket = Tickets.get_ticket!(loop.ticket_id)

    if ticket.status != :halted do
      _ = Tickets.update_ticket(ticket, %{status: :halted}, skip_hooks: true)
    end

    :ok
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_map, _key), do: nil

  defp repair_handoff(loop, dn, err, sid, state) do
    repairs = Map.get(state.checker_handoff_repairs, loop.id, 0) + 1

    if repairs > @max_handoff_repairs do
      do_retry(loop, "Checker handoff invalid: #{err}", dn, fail_hr(state, loop, sid, err))
    else
      case ensure_daemon(loop, dn) do
        {:ok, daemon} ->
          task = PromptBuilder.checker_handoff_repair_task(loop, err, repairs, ws_slug_for(loop))

          pl =
            Map.merge(
              %{"role" => "checker", "task" => task, "attempt" => loop.current_attempt},
              scoped_run_context(state, loop)
            )

          {:ok, state |> put_hr(loop.id, repairs) |> push(daemon.name, loop.id, pl)}

        _ ->
          {:ok, fail_hr(state, loop, sid, err)}
      end
    end
  end

  defp fail_hr(state, loop, sid, err) do
    Loops.complete_last_running(loop.id, "checker", loop.current_attempt, %{
      session_id: sid,
      verdict: "fail",
      feedback: "Invalid checker handoff: #{err}",
      status: "handoff_invalid"
    })

    clear_hr(state, loop.id)
  end

  defp maybe_complete_ticket(loop) do
    task_loops =
      loop.ticket_id
      |> Loops.list_task_loops_for_ticket()
      |> Enum.filter(&(&1.role == :task))

    all_tasks_passed? = task_loops != [] and Enum.all?(task_loops, &(&1.status == :passed))

    if all_tasks_passed? do
      Tickets.update_ticket(Tickets.get_ticket!(loop.ticket_id), %{status: :completed})
    end
  end

  defp ensure_daemon(_loop, dn) when is_binary(dn), do: fetch_daemon(dn)

  defp ensure_daemon(%{assigned_daemon_id: id}, _) when not is_nil(id) do
    case Daemons.get_daemon(id) do
      nil -> {:error, :daemon_not_found}
      daemon -> {:ok, daemon}
    end
  end

  defp ensure_daemon(_, _), do: Daemons.find_online()

  defp fetch_daemon(n),
    do: if(d = Daemons.get_daemon_by_name(n), do: {:ok, d}, else: {:error, :daemon_not_found})

  defp check_repo_ready(dn, loop) do
    ws = Loops.preload_with_workspace(loop).ticket.workspace

    if ws && ws.github_repo_url && !Daemons.repo_ready?(dn, ws.slug),
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

  defp ensure_ticket_workspace_subscription(state, workspace_id) do
    case workspace_id do
      nil ->
        state

      _ ->
        subscribed = Map.get(state, :subscribed_ticket_workspaces, MapSet.new())

        if MapSet.member?(subscribed, workspace_id) do
          state
        else
          Tickets.subscribe(workspace_id)

          Map.put(
            state,
            :subscribed_ticket_workspaces,
            MapSet.put(subscribed, workspace_id)
          )
        end
    end
  end

  defp run_with_workspace(workspace_id, fallback, fun) do
    case workspace_id do
      nil -> fallback
      _ -> TenantScope.with_workspace(workspace_id, fun)
    end
  end

  defp completion_phase(loop_id, payload) do
    case Loops.current_running_step(loop_id) do
      %{role: role} -> role
      _ -> payload_step_role(payload) || Loops.current_phase(loop_id)
    end
  end

  defp payload_step_role(payload) when is_map(payload) do
    role = Map.get(payload, "role")
    if role in ["maker", "checker"], do: role, else: nil
  end

  defp payload_step_role(_), do: nil

  defp fail_checker_transition(loop, attempt, reason, state) do
    error = "Checker transition error: #{format_transition_reason(reason)}"

    case Loops.complete_last_running(loop.id, "checker", attempt, %{
           status: "failed",
           error: error
         }) do
      {:ok, _step} ->
        :ok

      :not_found ->
        _ =
          Loops.create_step(%{
            loop_id: loop.id,
            role: "checker",
            attempt: attempt,
            status: "failed",
            error: error,
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now()
          })

        :ok

      _ ->
        :ok
    end

    _ = Loops.update_loop_status(loop, :failed)

    state
    |> clear_hr(loop.id)
    |> clear_rc(loop.id)
  end

  defp format_transition_reason(%{errors: _} = changeset), do: inspect(changeset.errors)

  defp format_transition_reason({:invalid_checker_config, errors}),
    do: format_checker_config_errors(errors)

  defp format_transition_reason(%_{} = error), do: Exception.message(error)
  defp format_transition_reason(reason), do: inspect(reason)

  defp validate_loop_checker_config(loop) do
    case Skills.validate_checker_config(loop.checker_config) do
      {:ok, _invocations, _registry} -> :ok
      {:error, errors, _registry} -> {:error, errors}
    end
  end

  defp format_checker_config_errors(errors) when is_list(errors) do
    "invalid checker_config: " <>
      Enum.map_join(errors, "; ", fn error ->
        path = Map.get(error, :path) || "checker_config"
        code = Map.get(error, :code) || "validation_error"
        message = Map.get(error, :message) || inspect(error)
        "#{path} [#{code}] #{message}"
      end)
  end

  defp workspace_id_for_loop(state, loop_id, explicit_workspace_id) do
    if explicit_workspace_id,
      do: explicit_workspace_id,
      else: rc(state, loop_id)["workspace_id"]
  end

  defp scoped_run_context(state, loop) do
    %{
      "agent_type" => Agents.ticket_agent_type(loop.ticket),
      "workspace_slug" => loop.ticket.workspace.slug,
      "ticket_id" => loop.ticket.id,
      "workspace_id" => loop.ticket.workspace_id
    }
    |> Map.merge(rc(state, loop.id))
  end

  defp ws_slug_for(%{ticket: %{workspace: %{slug: slug}}}), do: slug
  defp ws_slug_for(_), do: nil

  defp put_hr(s, id, n),
    do: %{s | checker_handoff_repairs: Map.put(s.checker_handoff_repairs, id, n)}

  defp clear_hr(s, id),
    do: %{s | checker_handoff_repairs: Map.delete(s.checker_handoff_repairs, id)}

  defp cleanup_ticket_worktree(ticket) do
    all_loops = running_loops_for_ticket(ticket.id) ++ completed_loops_for_ticket(ticket.id)

    daemon_id =
      all_loops
      |> Enum.map(& &1.assigned_daemon_id)
      |> Enum.reject(&is_nil/1)
      |> List.first()

    ticket = Algedonia.Repo.preload(ticket, :workspace)
    ws_slug = ticket.workspace && ticket.workspace.slug

    if daemon_id && ws_slug do
      daemon = Daemons.get_daemon!(daemon_id)

      AlgedoniaWeb.DaemonChannel.push_cleanup_worktree(
        daemon.name,
        ticket.id,
        ws_slug
      )
    end
  rescue
    _ -> :ok
  end

  defp completed_loops_for_ticket(ticket_id) do
    ticket_id
    |> Loops.list_loops_for_ticket()
    |> Enum.filter(&(&1.status in [:passed, :failed]))
  end

  defp guard_startable(%{status: :pending, current_attempt: ca}, max_attempts)
       when is_integer(max_attempts) and ca >= max_attempts,
       do: {:error, :attempts_exhausted}

  defp guard_startable(%{status: :pending}, _max_attempts), do: :ok
  defp guard_startable(_, _max_attempts), do: {:error, :already_running}

  defp loop_iteration_budget(%{
         ticket: %{workspace: %Algedonia.Workspaces.Workspace{} = workspace}
       }) do
    Workspaces.iteration_budget(workspace)
  end

  defp loop_iteration_budget(%{workspace_id: workspace_id}) when is_binary(workspace_id) do
    Workspaces.iteration_budget(workspace_id)
  end

  defp loop_iteration_budget(_), do: Workspaces.default_iteration_budget()

  defp default_push(dn, lid, opts),
    do: AlgedoniaWeb.DaemonChannel.push_start_loop(dn, lid, opts)

  defp step_to_map(step) do
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
  end
end
