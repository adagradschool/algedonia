defmodule Algedonia.ReviewLoop do
  @moduledoc """
  Orchestrates the In Review auto-land loop: commit → push → PR → CI/review
  polling → merge detection → ticket completion.

  Runs as a GenServer that manages review loop lifecycle, polling timers,
  and inactivity pauses.
  """
  use GenServer

  require Logger

  alias Algedonia.{
    Agents,
    Daemons,
    Loops,
    PromptBuilder,
    TenantScope,
    Tickets,
    Workspaces
  }

  @inactivity_timeout_ms 15 * 60 * 1000
  @poll_interval_ms 30_000

  @doc "Starts the ReviewLoop GenServer."
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
  Starts a review loop for a ticket that just entered :in_review.

  Creates the review loop if one doesn't already exist, and dispatches the
  first review agent run.
  """
  @spec start_review(map(), keyword()) :: :ok | {:error, term()}
  def start_review(ticket, opts \\ []) do
    call_if_alive(opts, {:start_review, ticket}, {:error, :review_loop_not_running})
  end

  @doc "Handles review agent completion."
  @spec handle_attempt_complete(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_attempt_complete(loop_id, payload, opts \\ []) do
    call_if_alive(
      opts,
      {:attempt_complete, loop_id, payload, Keyword.get(opts, :daemon_name),
       Keyword.get(opts, :workspace_id)},
      {:error, :review_loop_not_running}
    )
  end

  @doc "Handles review agent error."
  @spec handle_attempt_error(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_attempt_error(loop_id, payload, opts \\ []) do
    call_if_alive(
      opts,
      {:attempt_error, loop_id, payload, Keyword.get(opts, :daemon_name),
       Keyword.get(opts, :workspace_id)},
      {:error, :review_loop_not_running}
    )
  end

  @doc """
  Triggers an immediate PR comment fetch and resumes polling if paused.
  """
  @spec pull_comments(map(), keyword()) :: :ok | {:error, term()}
  def pull_comments(ticket, opts \\ []) do
    call_if_alive(opts, {:pull_comments, ticket}, {:error, :review_loop_not_running})
  end

  @doc """
  Called when a PR merge is detected. Completes the ticket.
  """
  @spec handle_merge_detected(binary(), keyword()) :: :ok | {:error, term()}
  def handle_merge_detected(loop_id, opts \\ []) do
    call_if_alive(
      opts,
      {:merge_detected, loop_id, Keyword.get(opts, :workspace_id)},
      {:error, :review_loop_not_running}
    )
  end

  defp call_if_alive(opts, msg, default) do
    case GenServer.whereis(Keyword.get(opts, :name, __MODULE__)) do
      nil -> default
      pid -> GenServer.call(pid, msg)
    end
  end

  @impl true
  def init(state) do
    {:ok,
     Map.merge(state, %{
       review_loops: %{},
       poll_timers: %{},
       subscribed_workspaces: MapSet.new()
     })}
  end

  @impl true
  def handle_call({:start_review, ticket}, _from, state) do
    state = ensure_subscription(state, ticket.workspace_id)

    case run_with_workspace(ticket.workspace_id, {:error, :workspace_scope_required}, fn ->
           do_start_review(ticket, state)
         end) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:attempt_complete, loop_id, payload, daemon_name, workspace_id}, _from, state) do
    case run_with_workspace(workspace_id, {:error, :workspace_scope_required}, fn ->
           do_handle_complete(loop_id, payload, daemon_name, state)
         end) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:attempt_error, loop_id, payload, daemon_name, workspace_id}, _from, state) do
    case run_with_workspace(workspace_id, {:error, :workspace_scope_required}, fn ->
           do_handle_error(loop_id, payload, daemon_name, state)
         end) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:pull_comments, ticket}, _from, state) do
    case run_with_workspace(ticket.workspace_id, {:error, :workspace_scope_required}, fn ->
           do_pull_comments(ticket, state)
         end) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:merge_detected, loop_id, workspace_id}, _from, state) do
    case run_with_workspace(workspace_id, {:error, :workspace_scope_required}, fn ->
           do_merge_detected(loop_id, state)
         end) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_info({:poll_review, loop_id}, state) do
    state = Map.update!(state, :poll_timers, &Map.delete(&1, loop_id))

    case Map.get(state.review_loops, loop_id) do
      nil ->
        {:noreply, state}

      %{workspace_id: workspace_id} = info ->
        new_state =
          run_with_workspace(workspace_id, state, fn ->
            do_poll_review(loop_id, info, state)
          end)

        {:noreply, new_state}
    end
  end

  def handle_info({:ticket_updated, %{status: :in_review}}, state), do: {:noreply, state}

  def handle_info({:ticket_updated, %{status: status} = ticket}, state)
      when status in [:halted, :archived] do
    new_state =
      run_with_workspace(ticket.workspace_id, state, fn ->
        stop_review_loops_for_ticket(ticket.id, state)
      end)

    {:noreply, new_state}
  end

  def handle_info({:ticket_updated, _ticket}, state), do: {:noreply, state}
  def handle_info({:ticket_created, _ticket}, state), do: {:noreply, state}
  def handle_info({:ticket_deleted, _ticket}, state), do: {:noreply, state}

  # -- Core operations --

  defp do_start_review(ticket, state) do
    existing = Loops.list_review_loops_for_ticket(ticket.id)
    running = Enum.find(existing, &(&1.status in [:pending, :running]))

    if running do
      {:ok, state}
    else
      with {:ok, daemon} <- Daemons.find_online(),
           {:ok, loop} <- create_review_loop(ticket),
           {:ok, loop} <-
             Loops.update_loop(loop, %{
               status: :running,
               assigned_daemon_id: daemon.id,
               current_attempt: 1
             }) do
        loop = Loops.preload_with_workspace(loop)
        agent_link = build_agent_link(loop)
        task = PromptBuilder.review_task(loop, ticket, "", agent_link)
        ws_slug = loop.ticket.workspace.slug

        {:ok, _step} =
          Loops.create_step(%{
            loop_id: loop.id,
            role: "review",
            attempt: loop.current_attempt,
            status: "running",
            started_at: DateTime.utc_now()
          })

        payload = %{
          "role" => "review",
          "task" => task,
          "agent_type" => Agents.ticket_agent_type(ticket),
          "workspace_slug" => ws_slug,
          "ticket_id" => ticket.id,
          "workspace_id" => ticket.workspace_id
        }

        info = %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          daemon_name: daemon.name,
          agent_link: agent_link,
          last_activity_at: DateTime.utc_now()
        }

        state =
          state
          |> put_in([Access.key(:review_loops), loop.id], info)
          |> push_to_daemon(daemon.name, loop.id, payload)

        {:ok, state}
      end
    end
  end

  defp do_handle_complete(loop_id, payload, _daemon_name, state) do
    case Loops.get_loop(loop_id) do
      %{role: :review} = loop ->
        loop = Loops.preload_with_workspace(loop)
        sid = Map.get(payload, "session_id")
        ec = Map.get(payload, "exit_code", 0)

        Loops.complete_last_running(loop.id, "review", loop.current_attempt, %{
          session_id: sid,
          exit_code: ec,
          status: "completed"
        })

        pr_url = Map.get(payload, "pr_url")
        pr_number = Map.get(payload, "pr_number")
        merged = Map.get(payload, "merged", false)

        ticket = Tickets.get_ticket!(loop.ticket_id)
        maybe_record_pr_linkage(ticket, pr_url, pr_number)

        state = touch_activity(state, loop_id)

        if merged do
          do_merge_detected(loop_id, state)
        else
          state = schedule_poll(state, loop_id)
          {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  defp do_handle_error(loop_id, payload, daemon_name, state) do
    case Loops.get_loop(loop_id) do
      %{role: :review} = loop ->
        loop = Loops.preload_with_workspace(loop)
        sid = Map.get(payload, "session_id")
        ec = Map.get(payload, "exit_code", 1)
        message = Map.get(payload, "message", "review agent exited with code #{ec}")

        Loops.complete_last_running(loop.id, "review", loop.current_attempt, %{
          session_id: sid,
          exit_code: ec,
          status: "failed",
          error: message
        })

        state = touch_activity(state, loop_id)

        max_attempts = loop_iteration_budget(loop)

        if loop.current_attempt >= max_attempts do
          {:ok, _} = Loops.update_loop_status(loop, :failed)
          {:ok, cleanup_loop(state, loop_id)}
        else
          retry_review(loop, daemon_name, "Review agent failed: #{message}", state)
        end

      _ ->
        {:ok, state}
    end
  end

  defp do_pull_comments(ticket, state) do
    review_loops = Loops.list_review_loops_for_ticket(ticket.id)
    running = Enum.find(review_loops, &(&1.status == :running))

    case running do
      nil ->
        {:ok, state}

      loop ->
        loop = Loops.preload_with_workspace(loop)
        info = Map.get(state.review_loops, loop.id, %{})
        daemon_name = info[:daemon_name]

        # Resume polling (un-pause)
        ticket = Tickets.get_ticket!(ticket.id)

        if ticket.review_paused do
          Tickets.update_ticket(ticket, %{review_paused: false}, skip_hooks: true)
        end

        state = touch_activity(state, loop.id)

        # Re-dispatch review agent with fresh feedback
        retry_review(
          loop,
          daemon_name,
          "User requested pull comments - fetch and address latest PR review feedback.",
          state
        )
    end
  end

  defp do_poll_review(loop_id, info, state) do
    case Loops.get_loop(loop_id) do
      %{role: :review, status: :running} = loop ->
        ticket = Tickets.get_ticket!(loop.ticket_id)
        poll_running_review(loop_id, loop, ticket, info, state)

      _ ->
        cleanup_loop(state, loop_id)
    end
  end

  defp poll_running_review(loop_id, _loop, %{status: status}, _info, state)
       when status != :in_review do
    cleanup_loop(state, loop_id)
  end

  defp poll_running_review(loop_id, loop, ticket, info, state) do
    last_activity = info[:last_activity_at] || DateTime.utc_now()
    elapsed_ms = DateTime.diff(DateTime.utc_now(), last_activity, :millisecond)

    if elapsed_ms >= @inactivity_timeout_ms do
      Logger.info("Review loop #{loop_id}: pausing after #{@inactivity_timeout_ms}ms inactivity")

      Tickets.update_ticket(ticket, %{review_paused: true}, skip_hooks: true)
      state
    else
      poll_dispatch_review(loop, info, state, loop_id)
    end
  end

  defp poll_dispatch_review(loop, info, state, loop_id) do
    loop = Loops.preload_with_workspace(loop)
    daemon_name = info[:daemon_name]

    case retry_review(
           loop,
           daemon_name,
           "Poll: check CI status, PR reviews, and merge state. If PR is merged, exit immediately. If review comments or CI failures need attention, fix them.",
           state
         ) do
      {:ok, new_state} -> new_state
      {:error, _} -> schedule_poll(state, loop_id)
    end
  end

  defp do_merge_detected(loop_id, state) do
    case Loops.get_loop(loop_id) do
      %{role: :review} = loop ->
        {:ok, _} = Loops.update_loop_status(loop, :passed)

        ticket = Tickets.get_ticket!(loop.ticket_id)

        if ticket.status == :in_review do
          Tickets.update_ticket(ticket, %{status: :completed})
        end

        {:ok, cleanup_loop(state, loop_id)}

      _ ->
        {:ok, state}
    end
  end

  # -- Retry --

  defp retry_review(loop, daemon_name, feedback, state) do
    max_attempts = loop_iteration_budget(loop)

    if loop.current_attempt >= max_attempts do
      {:ok, _} = Loops.update_loop_status(loop, :failed)
      {:ok, cleanup_loop(state, loop.id)}
    else
      with {:ok, daemon} <- ensure_daemon(loop, daemon_name),
           {:ok, loop} <-
             Loops.update_loop(loop, %{
               status: :running,
               current_attempt: loop.current_attempt + 1,
               max_attempts: max_attempts
             }) do
        loop = Loops.preload_with_workspace(loop)
        ticket = loop.ticket
        agent_link = Map.get(state.review_loops, loop.id, %{})[:agent_link]
        task = PromptBuilder.review_task(loop, ticket, feedback, agent_link)

        {:ok, _step} =
          Loops.create_step(%{
            loop_id: loop.id,
            role: "review",
            attempt: loop.current_attempt,
            status: "running",
            started_at: DateTime.utc_now()
          })

        payload = %{
          "role" => "review",
          "task" => task,
          "agent_type" => Agents.ticket_agent_type(ticket),
          "workspace_slug" => loop.ticket.workspace.slug,
          "ticket_id" => ticket.id,
          "workspace_id" => ticket.workspace_id
        }

        {:ok, push_to_daemon(state, daemon.name, loop.id, payload)}
      else
        _ -> {:error, :retry_failed}
      end
    end
  end

  # -- Helpers --

  defp create_review_loop(ticket) do
    Loops.create_loop(%{
      workspace_id: ticket.workspace_id,
      ticket_id: ticket.id,
      title: "Review: #{ticket.title}",
      description: "Auto-land review loop",
      role: :review,
      status: :pending,
      max_attempts: Workspaces.iteration_budget(ticket.workspace_id)
    })
  end

  defp build_agent_link(loop) do
    ws = loop.ticket.workspace

    ticket_ref =
      if loop.ticket.number, do: Integer.to_string(loop.ticket.number), else: loop.ticket.id

    loop_ref = String.slice(loop.id, 0, 8)
    "/w/#{ws.slug}/tickets/#{ticket_ref}/loops/#{loop_ref}"
  end

  defp maybe_record_pr_linkage(ticket, pr_url, pr_number) do
    attrs = %{}
    attrs = if pr_url, do: Map.put(attrs, :review_pr_url, pr_url), else: attrs
    attrs = if pr_number, do: Map.put(attrs, :review_pr_number, pr_number), else: attrs

    if attrs != %{} do
      Tickets.update_ticket(ticket, attrs, skip_hooks: true)
    end
  end

  defp schedule_poll(state, loop_id) do
    cancel_poll_timer(state, loop_id)
    ref = Process.send_after(self(), {:poll_review, loop_id}, @poll_interval_ms)
    put_in(state, [Access.key(:poll_timers), loop_id], ref)
  end

  defp cancel_poll_timer(state, loop_id) do
    case Map.get(state.poll_timers, loop_id) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    state
  end

  defp touch_activity(state, loop_id) do
    now = DateTime.utc_now()

    update_in(state, [Access.key(:review_loops), loop_id], fn
      nil -> %{last_activity_at: now}
      info -> Map.put(info, :last_activity_at, now)
    end)
  end

  defp cleanup_loop(state, loop_id) do
    cancel_poll_timer(state, loop_id)

    state
    |> Map.update!(:review_loops, &Map.delete(&1, loop_id))
    |> Map.update!(:poll_timers, &Map.delete(&1, loop_id))
  end

  defp stop_review_loops_for_ticket(ticket_id, state) do
    review_loops = Loops.list_review_loops_for_ticket(ticket_id)

    Enum.reduce(review_loops, state, fn loop, acc ->
      fail_running_review_loop(loop, acc)
      cleanup_loop(acc, loop.id)
    end)
  end

  defp fail_running_review_loop(%{status: :running} = loop, state) do
    daemon_name = Map.get(state.review_loops, loop.id, %{})[:daemon_name]

    if daemon_name do
      AlgedoniaWeb.DaemonChannel.push_stop_loop(daemon_name, loop.id, "ticket status changed")
    end

    {:ok, _} = Loops.update_loop_status(loop, :failed)
  end

  defp fail_running_review_loop(_loop, _state), do: :noop

  defp push_to_daemon(state, daemon_name, loop_id, payload) do
    state.push_fn.(daemon_name, loop_id, payload)
    state
  end

  defp ensure_daemon(_loop, dn) when is_binary(dn) do
    case Daemons.get_daemon_by_name(dn) do
      nil -> Daemons.find_online()
      daemon -> {:ok, daemon}
    end
  end

  defp ensure_daemon(%{assigned_daemon_id: id}, _) when not is_nil(id) do
    case Daemons.get_daemon(id) do
      nil -> Daemons.find_online()
      daemon -> {:ok, daemon}
    end
  end

  defp ensure_daemon(_, _), do: Daemons.find_online()

  defp ensure_subscription(state, workspace_id) do
    if MapSet.member?(state.subscribed_workspaces, workspace_id) do
      state
    else
      Tickets.subscribe(workspace_id)
      Map.update!(state, :subscribed_workspaces, &MapSet.put(&1, workspace_id))
    end
  end

  defp run_with_workspace(workspace_id, fallback, fun) do
    case workspace_id do
      nil -> fallback
      _ -> TenantScope.with_workspace(workspace_id, fun)
    end
  end

  defp loop_iteration_budget(%{ticket: %{workspace: %Algedonia.Workspaces.Workspace{} = ws}}) do
    Workspaces.iteration_budget(ws)
  end

  defp loop_iteration_budget(%{workspace_id: workspace_id}) when is_binary(workspace_id) do
    Workspaces.iteration_budget(workspace_id)
  end

  defp loop_iteration_budget(_), do: Workspaces.default_iteration_budget()

  defp default_push(dn, lid, opts),
    do: AlgedoniaWeb.DaemonChannel.push_start_loop(dn, lid, opts)
end
