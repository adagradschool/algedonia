defmodule Algedonia.ReviewLoop do
  @moduledoc """
  Orchestrates the In Review auto-land loop: commit → push → PR → CI/review
  polling → merge detection → ticket completion.

  Runs as a GenServer that keeps a review agent alive until merge, polls the PR
  in the background, and nudges the active agent over stdin when review state changes.
  """
  use GenServer

  alias Algedonia.{
    Agents,
    Daemons,
    Loops,
    PromptBuilder,
    PubSub.Topics,
    TenantScope,
    Tickets,
    Workspaces
  }

  @poll_interval_ms 30_000
  @empty_feedback_token "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @doc "Starts the ReviewLoop GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {push_fn, opts} = Keyword.pop(opts, :push_fn, &default_push/3)
    {poll_fn, opts} = Keyword.pop(opts, :poll_fn, &default_poll/3)
    {stdin_fn, opts} = Keyword.pop(opts, :stdin_fn, &default_stdin/3)

    GenServer.start_link(
      __MODULE__,
      %{push_fn: push_fn, poll_fn: poll_fn, stdin_fn: stdin_fn},
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
  Triggers an immediate PR comment fetch through the active review agent.
  """
  @spec pull_comments(map(), keyword()) :: :ok | {:error, term()}
  def pull_comments(ticket, opts \\ []) do
    call_if_alive(opts, {:pull_comments, ticket}, {:error, :review_loop_not_running})
  end

  @doc "Handles background PR poll results from the daemon."
  @spec handle_pr_status(binary(), map(), keyword()) :: :ok | {:error, term()}
  def handle_pr_status(loop_id, payload, opts \\ []) do
    call_if_alive(
      opts,
      {:pr_status, loop_id, payload, Keyword.get(opts, :workspace_id)},
      {:error, :review_loop_not_running}
    )
  end

  @doc "Returns background poll state for a review loop."
  @spec poll_state(binary(), keyword()) :: map() | nil
  def poll_state(loop_id, opts \\ []) do
    call_if_alive(opts, {:poll_state, loop_id}, nil)
  end

  @doc "Rehydrates in-review loops and ensures review agents are running when needed."
  @spec reconcile_running_reviews(keyword()) :: :ok | {:error, term()}
  def reconcile_running_reviews(opts \\ []) do
    call_if_alive(opts, {:reconcile_reviews, opts}, {:error, :review_loop_not_running})
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

  def handle_call({:pr_status, loop_id, payload, workspace_id}, _from, state) do
    case run_with_workspace(workspace_id, {:error, :workspace_scope_required}, fn ->
           do_handle_pr_status(loop_id, payload, state)
         end) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:poll_state, loop_id}, _from, state) do
    {:reply, Map.get(state.review_loops, loop_id), state}
  end

  def handle_call({:reconcile_reviews, opts}, _from, state) do
    {:reply, :ok, reconcile_reviews(state, opts)}
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
      running
      |> Loops.preload_with_workspace()
      |> ensure_review_runtime(state, start_agent?: false)
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

        task =
          PromptBuilder.review_task(loop, ticket, "", review_prompt_metadata(loop, agent_link))

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
          last_activity_at: DateTime.utc_now(),
          last_polled_at: nil,
          last_ci_state: nil,
          feedback_token: nil
        }

        state =
          state
          |> put_in([Access.key(:review_loops), loop.id], info)
          |> push_to_daemon(daemon.name, loop.id, payload)
          |> schedule_poll(loop.id)

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
        do_start_review(ticket, state)

      loop ->
        with {:ok, state} <-
               loop
               |> Loops.preload_with_workspace()
               |> ensure_review_runtime(state, start_agent?: true) do
          state =
            state
            |> touch_activity(loop.id)
            |> nudge_review_agent(
              loop.id,
              "Fetch the latest PR review feedback with `pr-review-feedback`, address anything actionable, and push updates if needed."
            )

          {:ok, state}
        end
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

  defp poll_running_review(loop_id, loop, ticket, _info, state) do
    case ensure_review_runtime(Loops.preload_with_workspace(loop), state, start_agent?: false) do
      {:ok, state} ->
        if is_integer(ticket.review_pr_number) do
          poll_dispatch_review(loop_id, ticket, state)
        else
          schedule_poll(state, loop_id)
        end

      {:error, _} ->
        schedule_poll(state, loop_id)
    end
  end

  defp poll_dispatch_review(loop_id, ticket, state) do
    daemon_name = state.review_loops[loop_id][:daemon_name]

    payload = %{
      "workspace_slug" => workspace_slug_for_state(loop_id, state),
      "ticket_id" => ticket.id,
      "pr_number" => ticket.review_pr_number
    }

    state.poll_fn.(daemon_name, loop_id, payload)

    schedule_poll(state, loop_id)
  end

  defp do_handle_pr_status(loop_id, payload, state) do
    case Loops.get_loop(loop_id) do
      %{role: :review, status: :running} = loop ->
        ticket = Tickets.get_ticket!(loop.ticket_id)
        feedback_changed = feedback_changed?(state, loop_id, payload)
        state = update_poll_state(state, loop_id, payload)
        maybe_record_pr_linkage(ticket, Map.get(payload, "pr_url"), Map.get(payload, "pr_number"))

        cond do
          Map.get(payload, "merged") ->
            do_merge_detected(loop_id, state)

          Map.get(payload, "ok") == false ->
            {:ok, state}

          Map.get(payload, "ci_state") == "failure" ->
            {:ok,
             nudge_review_agent(
               state,
               loop_id,
               "Required CI is failing on the PR. Inspect the failing checks, fix the issues, and push updates."
             )}

          feedback_changed ->
            {:ok,
             nudge_review_agent(
               state,
               loop_id,
               "There is new PR feedback. Use `pr-review-feedback`, address anything actionable, and push updates if needed."
             )}

          true ->
            {:ok, state}
        end

      _ ->
        {:ok, state}
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

        task =
          PromptBuilder.review_task(
            loop,
            ticket,
            feedback,
            review_prompt_metadata(loop, agent_link)
          )

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
    workspace = Workspaces.get_workspace(ticket.workspace_id)

    Loops.create_loop(%{
      workspace_id: ticket.workspace_id,
      ticket_id: ticket.id,
      title: "Review #{ticket_code(ticket, workspace)}: #{ticket.title}",
      description:
        "Auto-land #{ticket_code(ticket, workspace)} via branch, PR, CI, and review follow-up",
      branch_name: suggested_branch_name(ticket, workspace),
      role: :review,
      status: :pending,
      max_attempts: Workspaces.iteration_budget(ticket.workspace_id)
    })
  end

  defp build_agent_link(loop) do
    ws = loop.ticket.workspace
    ticket_ref = ticket_ref(loop.ticket)
    loop_ref = String.slice(loop.id, 0, 8)
    "/w/#{ws.slug}/tickets/#{ticket_ref}/loops/#{loop_ref}"
  end

  defp build_ticket_link(loop) do
    ws = loop.ticket.workspace
    "/w/#{ws.slug}/tickets/#{ticket_ref(loop.ticket)}"
  end

  defp maybe_record_pr_linkage(ticket, pr_url, pr_number) do
    attrs = %{}
    attrs = if pr_url, do: Map.put(attrs, :review_pr_url, pr_url), else: attrs
    attrs = if pr_number, do: Map.put(attrs, :review_pr_number, pr_number), else: attrs

    if attrs != %{} do
      Tickets.update_ticket(ticket, attrs, skip_hooks: true)
    end
  end

  defp reconcile_reviews(state, opts) do
    force_start? = Keyword.get(opts, :force_start, false)
    daemon_id = Keyword.get(opts, :daemon_id)

    if is_binary(daemon_id) do
      daemon_id
      |> Loops.list_running_loops_for_daemon()
      |> Enum.filter(&(&1.role == :review))
      |> Enum.reduce(state, &reconcile_review_loop(&1, &2, force_start?))
    else
      state
    end
  end

  defp reconcile_review_loop(loop, state, force_start?) do
    run_with_workspace(loop.workspace_id, state, fn ->
      case ensure_review_runtime(Loops.preload_with_workspace(loop), state,
             start_agent?: force_start?
           ) do
        {:ok, new_state} -> new_state
        _ -> state
      end
    end)
  end

  defp ensure_review_runtime(loop, state, opts) do
    start_agent? = Keyword.get(opts, :start_agent?, false) || loop.status == :pending
    info = Map.get(state.review_loops, loop.id)
    daemon_name = info && info[:daemon_name]

    with {:ok, daemon} <- ensure_daemon(loop, daemon_name) do
      state =
        state
        |> register_review_loop(loop, daemon.name)
        |> maybe_start_review_agent(loop, daemon, start_agent?)
        |> schedule_poll(loop.id)

      {:ok, state}
    end
  end

  defp register_review_loop(state, loop, daemon_name) do
    agent_link = build_agent_link(loop)
    workspace_id = loop.ticket.workspace_id

    state
    |> ensure_subscription(workspace_id)
    |> update_in([Access.key(:review_loops), loop.id], fn
      nil ->
        %{
          workspace_id: workspace_id,
          ticket_id: loop.ticket_id,
          daemon_name: daemon_name,
          agent_link: agent_link,
          last_activity_at: DateTime.utc_now(),
          last_polled_at: nil,
          last_ci_state: nil,
          feedback_token: nil
        }

      existing ->
        existing
        |> Map.put(:workspace_id, workspace_id)
        |> Map.put(:ticket_id, loop.ticket_id)
        |> Map.put(:daemon_name, daemon_name)
        |> Map.put(:agent_link, agent_link)
    end)
  end

  defp maybe_start_review_agent(state, loop, daemon, true) do
    start_review_agent(state, loop, daemon)
  end

  defp maybe_start_review_agent(state, _loop, _daemon, false), do: state

  defp start_review_agent(state, loop, daemon) do
    {:ok, loop} =
      Loops.update_loop(loop, %{
        status: :running,
        assigned_daemon_id: daemon.id
      })

    loop = Loops.preload_with_workspace(loop)
    ticket = loop.ticket
    agent_link = state.review_loops[loop.id][:agent_link]

    task = PromptBuilder.review_task(loop, ticket, "", review_prompt_metadata(loop, agent_link))

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

    state
    |> put_in([Access.key(:review_loops), loop.id, :daemon_name], daemon.name)
    |> touch_activity(loop.id)
    |> push_to_daemon(daemon.name, loop.id, payload)
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

  defp update_poll_state(state, loop_id, payload) do
    now =
      Map.get(payload, "polled_at")
      |> parse_polled_at()
      |> Kernel.||(DateTime.utc_now())

    state =
      update_in(state, [Access.key(:review_loops), loop_id], fn
        nil ->
          %{
            last_polled_at: now,
            last_ci_state: Map.get(payload, "ci_state"),
            feedback_token: Map.get(payload, "feedback_token")
          }

        info ->
          info
          |> Map.put(:last_polled_at, now)
          |> Map.put(:last_ci_state, Map.get(payload, "ci_state"))
          |> Map.put(:feedback_token, Map.get(payload, "feedback_token"))
      end)

    broadcast_poll_state(state, loop_id)
    state
  end

  defp feedback_changed?(state, loop_id, payload) do
    next_token = Map.get(payload, "feedback_token")
    current_token = get_in(state, [Access.key(:review_loops), loop_id, :feedback_token])

    cond do
      is_nil(next_token) ->
        false

      is_nil(current_token) ->
        next_token != @empty_feedback_token

      true ->
        current_token != next_token
    end
  end

  defp nudge_review_agent(state, loop_id, instruction) do
    case get_in(state, [Access.key(:review_loops), loop_id, :daemon_name]) do
      daemon_name when is_binary(daemon_name) ->
        state.stdin_fn.(
          daemon_name,
          loop_id,
          Base.encode64(String.trim(instruction) <> "\n")
        )

      _ ->
        :ok
    end

    touch_activity(state, loop_id)
  end

  defp workspace_slug_for_state(loop_id, _state) do
    case Loops.get_loop(loop_id) do
      %{ticket: %{workspace: %{slug: slug}}} -> slug
      %{workspace_id: workspace_id} -> Workspaces.get_workspace(workspace_id).slug
      _ -> nil
    end
  end

  defp broadcast_poll_state(state, loop_id) do
    case Map.get(state.review_loops, loop_id) do
      %{workspace_id: workspace_id} = info ->
        Phoenix.PubSub.broadcast(
          Algedonia.PubSub,
          Topics.loop(workspace_id, loop_id),
          {:review_poll_state, loop_id, info}
        )

      _ ->
        :ok
    end
  end

  defp parse_polled_at(nil), do: nil

  defp parse_polled_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_polled_at(_), do: nil

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
      %{status: :online} = daemon -> {:ok, daemon}
      _ -> Daemons.find_online()
    end
  end

  defp ensure_daemon(%{assigned_daemon_id: id}, _) when not is_nil(id) do
    case Daemons.get_daemon(id) do
      %{status: :online} = daemon -> {:ok, daemon}
      _ -> Daemons.find_online()
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

  defp default_poll(dn, lid, opts),
    do: AlgedoniaWeb.DaemonChannel.push_poll_review_pr(dn, lid, opts)

  defp default_stdin(dn, lid, data),
    do: AlgedoniaWeb.DaemonChannel.push_stdin_input(dn, lid, data)

  defp review_prompt_metadata(loop, agent_link) do
    workspace = loop.ticket.workspace
    ticket = loop.ticket
    ticket_link = build_ticket_link(loop)
    ticket_code = ticket_code(ticket, workspace)

    %{
      ticket_code: ticket_code,
      branch_name: loop.branch_name || suggested_branch_name(ticket, workspace),
      pr_title: "#{ticket_code}: #{ticket.title}",
      pr_description: suggested_pr_description(ticket_code, ticket_link, agent_link),
      ticket_link: ticket_link,
      agent_link: agent_link
    }
  end

  defp suggested_pr_description(ticket_code, ticket_link, agent_link) do
    sections = [
      "## Summary\n- Summarize the change shipped for #{ticket_code} in plain language.",
      "## Validation\n- Summarize the checks you ran before requesting review.",
      "## Links\n- Algedonia ticket: #{ticket_link}"
    ]

    sections =
      if is_binary(agent_link) and agent_link != "" do
        sections ++ ["- Review agent loop: #{agent_link}"]
      else
        sections
      end

    Enum.join(sections, "\n\n")
  end

  defp suggested_branch_name(ticket, workspace) do
    title_slug =
      ticket.title
      |> normalize_slug()
      |> String.slice(0, 48)

    "review/#{normalize_slug(ticket_code(ticket, workspace))}-#{title_slug}"
    |> String.trim_trailing("-")
  end

  defp ticket_code(ticket, workspace) do
    prefix =
      case workspace do
        %{prefix: prefix} when is_binary(prefix) and prefix != "" -> prefix
        _ -> "AG"
      end

    case ticket do
      %{number: number} when is_integer(number) -> "#{prefix}-#{number}"
      %{id: id} -> id
    end
  end

  defp ticket_ref(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  defp ticket_ref(%{id: id}), do: id

  defp normalize_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
