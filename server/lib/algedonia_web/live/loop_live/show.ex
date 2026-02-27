defmodule AlgedoniaWeb.LoopLive.Show do
  @moduledoc """
  LiveView for inspecting a loop's terminal output in real-time.
  """
  use AlgedoniaWeb, :live_view

  alias Algedonia.{Agents, Daemons, Loops, Orchestrator, Terminals, Tickets}
  alias AlgedoniaWeb.DaemonChannel
  alias AlgedoniaWeb.Markdown
  alias AlgedoniaWeb.TerminalAccessToken
  import AlgedoniaWeb.LoopComponents

  @status_to_stage %{
    running_checker: "checker",
    passed: "completed",
    failed: "failed"
  }

  @impl true
  def mount(
        %{"loop_ref" => loop_ref, "workspace" => workspace_slug} = params,
        _session,
        socket
      ) do
    loop_id = resolve_loop_id(loop_ref)

    if connected?(socket) do
      Terminals.subscribe(loop_id)
      maybe_subscribe_loop_updates(loop_id)
      maybe_subscribe_ticket_updates(loop_id)
    end

    socket = assign_loop_context(socket, loop_id)
    agent_type = default_agent_type(socket.assigns[:ticket])

    socket =
      socket
      |> assign(:loop_id, loop_id)
      |> assign(:loop_ref, loop_ref)
      |> assign(:route_ticket_ref, params["ticket_ref"])
      |> assign(:workspace_slug, workspace_slug)
      |> assign(:active, Terminals.active?(loop_id))
      |> assign(:role, "maker")
      |> assign(:agent_type, agent_type)
      |> assign(:auto_start_requested, false)
      |> assign(:show_steps, false)
      |> assign(:active_tab, "overview")
      |> assign(:overview_content, nil)
      |> assign(:overview_loading, false)
      |> assign(:overview_job_id, nil)
      |> assign(init_agent_ui(agent_type))
      |> assign(:show_shortcut_help, false)
      |> assign(:page_title, "Loop #{display_loop_id(loop_id)}")
      |> assign_history(Orchestrator.get_loop_history(loop_id))
      |> assign_terminal_run()
      |> assign_terminal_ws_access()

    if connected?(socket) do
      send(self(), {:send_scrollback, socket.assigns.selected_terminal_id})
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    role = params["role"] || socket.assigns.role

    socket =
      socket
      |> assign(:role, role)
      |> assign(
        :agent_type,
        params["agent_type"] || socket.assigns.agent_type || Agents.default_coding_agent_string()
      )

    socket =
      if connected?(socket) && params["autostart"] == "1" && !socket.assigns.active &&
           !socket.assigns.auto_start_requested do
        send(self(), :auto_start_loop)
        assign(socket, :auto_start_requested, true)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_loop", _params, socket) do
    {:noreply, start_loop_on_daemon(socket)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ["overview", "rubric"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("switch_tab", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_steps", _params, socket) do
    {:noreply, assign(socket, :show_steps, !socket.assigns.show_steps)}
  end

  def handle_event("select_step", %{"step_id" => step_id}, socket) do
    socket =
      socket
      |> assign(:selected_step_id, step_id)
      |> assign_terminal_run()
      |> assign_terminal_ws_access()

    if connected?(socket) do
      send(self(), {:send_scrollback, socket.assigns.selected_terminal_id})
    end

    {:noreply, socket}
  end

  def handle_event("toggle_shortcut_help", _params, socket) do
    {:noreply, assign(socket, :show_shortcut_help, !socket.assigns.show_shortcut_help)}
  end

  def handle_event("shortcut_toggle_loop", _params, socket) do
    if socket.assigns.active do
      handle_event("stop_loop", %{}, socket)
    else
      handle_event("start_loop", %{}, socket)
    end
  end

  def handle_event("shortcut_back", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets")}
  end

  def handle_event("rubric_change", %{"body" => body}, socket) do
    case socket.assigns.loop_record do
      nil ->
        {:noreply, socket}

      loop ->
        {:ok, updated} = Loops.update_loop(loop, %{rubric: body})
        {:noreply, assign(socket, loop_record: updated, rubric: body)}
    end
  end

  def handle_event("stop_loop", _params, socket) do
    with {:ok, daemon} <- resolve_daemon(socket) do
      DaemonChannel.push_stop_loop(daemon.name, socket.assigns.loop_id)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:auto_start_loop, socket) do
    {:noreply, start_loop_on_daemon(socket)}
  end

  @impl true
  def handle_info({:send_scrollback, terminal_id}, socket) do
    scrollback = Terminals.get_scrollback(terminal_id)
    encoded = Base.encode64(scrollback)
    {:noreply, push_event(socket, "terminal_scrollback", %{data: encoded})}
  end

  def handle_info({:terminal_data, loop_id, _data}, socket) do
    if loop_id == socket.assigns.loop_id do
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:terminal_ended, loop_id, exit_code}, socket) do
    cond do
      loop_id == socket.assigns.loop_id ->
        socket =
          socket
          |> push_event("terminal_ended", %{exit_code: exit_code})
          |> assign(:active, false)
          |> assign_history(Orchestrator.get_loop_history(socket.assigns.loop_id))
          |> assign_terminal_run()
          |> assign_terminal_ws_access()

        {:noreply, socket}

      loop_id == socket.assigns.selected_terminal_id ->
        {:noreply, push_event(socket, "terminal_ended", %{exit_code: exit_code})}

      loop_id == socket.assigns.overview_job_id ->
        overview = Terminals.get_scrollback(loop_id)

        {:noreply,
         socket
         |> assign(:overview_loading, false)
         |> assign(:overview_job_id, nil)
         |> assign(:overview_content, overview)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:loop_updated, loop}, socket) do
    loop = Loops.preload_ticket(loop)

    {:noreply,
     socket
     |> assign(:loop_record, loop)
     |> assign(:ticket, loop.dag.ticket)
     |> assign(:loop_title, loop.title)
     |> assign(:stage, Map.get(@status_to_stage, loop.status, "maker"))
     |> assign(:attempt, max(loop.current_attempt, 1))
     |> assign(:rubric, loop.rubric || loop.dag.ticket.rubric || "")
     |> assign_terminal_run()
     |> assign_terminal_ws_access()}
  end

  def handle_info({:loop_history_updated, history}, socket) do
    previous_terminal_id = socket.assigns.selected_terminal_id
    was_following_current = following_current_step?(socket)

    socket =
      if was_following_current do
        # Auto-advance: clear manual selection so we pick the new current step
        assign(socket, :selected_step_id, nil)
      else
        socket
      end

    socket =
      socket
      |> assign_history(history)
      |> assign_terminal_run()
      |> assign_terminal_ws_access()

    if connected?(socket) && socket.assigns.selected_terminal_id != previous_terminal_id do
      send(self(), {:send_scrollback, socket.assigns.selected_terminal_id})
    end

    {:noreply, socket}
  end

  def handle_info({event, ticket}, socket) when event in [:ticket_updated] do
    if socket.assigns.ticket && socket.assigns.ticket.id == ticket.id do
      agent_type = default_agent_type(ticket)

      {:noreply,
       socket
       |> assign(:ticket, ticket)
       |> assign(:agent_type, agent_type)
       |> assign(init_agent_ui(agent_type))
       |> assign(:acceptance_criteria, ticket.acceptance_criteria || "")}
    else
      {:noreply, socket}
    end
  end

  def render_markdown(text), do: Markdown.render(text)

  def verdict_heading(final_verdict, loop_record) do
    if final_outcome?(final_verdict, loop_record), do: "Final Verdict", else: "Checker Verdict"
  end

  defp start_loop_on_daemon(socket) do
    case resolve_daemon(socket) do
      {:error, :no_online_daemon} ->
        put_flash(socket, :error, "No online daemon available")

      {:ok, daemon} ->
        if socket.assigns.loop_record do
          start_persisted_loop(socket, daemon.name)
        else
          start_ad_hoc_loop(socket, daemon.name)
        end
    end
  end

  defp start_persisted_loop(socket, daemon_name) do
    case Orchestrator.start_task_loop(socket.assigns.loop_id, daemon_name,
           model: socket.assigns.selected_model,
           effort: socket.assigns.selected_effort,
           agent_type: socket.assigns.agent_type
         ) do
      :ok ->
        socket
        |> assign(:active, true)
        |> assign_history(Orchestrator.get_loop_history(socket.assigns.loop_id))
        |> maybe_start_overview_generation()

      {:error, _} ->
        put_flash(socket, :error, "Unable to start loop")
    end
  end

  defp start_ad_hoc_loop(socket, daemon_name) do
    opts =
      %{}
      |> maybe_put("role", socket.assigns[:role])
      |> maybe_put("agent_type", socket.assigns[:agent_type])
      |> maybe_put("model", socket.assigns[:selected_model])
      |> maybe_put("effort", socket.assigns[:selected_effort])

    DaemonChannel.push_start_loop(daemon_name, socket.assigns.loop_id, opts)

    socket
    |> assign(:active, true)
    |> maybe_start_overview_generation()
  end

  defp maybe_start_overview_generation(socket) do
    cond do
      socket.assigns.ticket == nil ->
        socket

      socket.assigns.overview_loading ->
        socket

      true ->
        case Daemons.find_online() do
          {:error, :no_online_daemon} ->
            socket

          {:ok, daemon} ->
            job_id = "overview-#{socket.assigns.loop_id}-#{System.unique_integer([:positive])}"
            Terminals.subscribe(job_id)

            DaemonChannel.push_start_loop(daemon.name, job_id, %{
              "role" => "overview",
              "agent_type" => "claude_code",
              "model" =>
                Application.get_env(:algedonia, :overview_model, "claude-haiku-4-5-20251001"),
              "task" => overview_task(socket)
            })

            socket
            |> assign(:overview_loading, true)
            |> assign(:overview_job_id, job_id)
        end
    end
  end

  defp overview_task(socket) do
    ticket = socket.assigns.ticket
    loop = socket.assigns.loop_record

    """
    You are generating a concise overview panel for a coding task. This will be displayed in a small sidebar, so be brief and scannable. Output only markdown, no commentary.

    ## Input Context

    **Ticket:** #{ticket.title}
    #{ticket.description || "(no description)"}

    **Acceptance Criteria:**
    #{ticket.acceptance_criteria || "(none specified)"}

    **Loop Task:** #{loop.title}
    #{loop.description || "(no description)"}

    **Rubric:**
    #{socket.assigns.rubric || "(none)"}

    ## Output Format

    Write compact markdown with exactly these sections:

    ### Context
    One short paragraph summarizing what this task is about and why it matters.

    ### Acceptance Criteria
    - Bullet list of concrete, testable criteria derived from the ticket and rubric
    - Keep each bullet to one line

    ### Scope
    Brief note on which files/areas are likely affected and any constraints.

    Rules:
    - Be concise — the panel is 24rem wide
    - No filler phrases ("This task aims to...", "The goal is...")
    - Start each section with substance, not preamble
    - Use **bold** for key terms only
    """
  end

  defp maybe_put(map, key, value), do: AlgedoniaWeb.Helpers.maybe_put(map, key, value)

  defp default_agent_type(ticket), do: Agents.ticket_agent_type(ticket)

  defp assign_loop_context(socket, loop_id) do
    loop = Loops.get_loop_by_ref(loop_id)

    case loop do
      nil ->
        socket
        |> assign(:loop_record, nil)
        |> assign(:ticket, nil)
        |> assign(:loop_title, "Ad hoc loop")
        |> assign(:stage, "maker")
        |> assign(:attempt, 1)
        |> assign(:rubric, "")
        |> assign(:acceptance_criteria, "")

      loop ->
        loop = Loops.preload_ticket(loop)
        ticket = loop.dag.ticket

        socket
        |> assign(:loop_record, loop)
        |> assign(:ticket, ticket)
        |> assign(:loop_title, loop.title)
        |> assign(:stage, Map.get(@status_to_stage, loop.status, "maker"))
        |> assign(:attempt, max(loop.current_attempt, 1))
        |> assign(:rubric, loop.rubric || ticket.rubric || "")
        |> assign(:acceptance_criteria, ticket.acceptance_criteria || "")
    end
  end

  defp maybe_subscribe_loop_updates(loop_id) do
    case Loops.get_loop_by_ref(loop_id) do
      nil -> :ok
      loop -> Loops.subscribe(loop.id)
    end
  end

  defp maybe_subscribe_ticket_updates(loop_id) do
    with %{} = loop <- Loops.get_loop_by_ref(loop_id),
         loop <- Loops.preload_ticket(loop) do
      Tickets.subscribe()
      Tickets.subscribe_comments(loop.dag.ticket_id)
    end
  end

  defp resolve_loop_id(loop_ref) do
    case Loops.get_loop_by_ref(loop_ref) do
      nil -> loop_ref
      loop -> loop.id
    end
  end

  def loop_show_path(workspace_slug, ticket, route_ticket_ref, loop_id) do
    ticket_ref = if ticket, do: ticket_ref(ticket), else: route_ticket_ref || "ad-hoc"

    ~p"/w/#{workspace_slug}/tickets/#{ticket_ref}/loops/#{String.slice(loop_id, 0, 8)}"
  end

  defp ticket_ref(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  defp ticket_ref(%{id: id}), do: id

  defp display_loop_id(loop_id), do: String.slice(loop_id, 0, 8)

  defp assign_history(socket, history) do
    step_history = step_history(history)
    current_step_id = current_step_id(socket, step_history)

    selected_step_id =
      selected_step_id(step_history, socket.assigns[:selected_step_id], current_step_id)

    socket
    |> assign(:history, history)
    |> assign(:step_history, step_history)
    |> assign(:selected_step_id, selected_step_id)
    |> assign(:current_step_id, current_step_id)
    |> assign(:final_verdict, extract_final_verdict(history))
  end

  defp extract_final_verdict(history) do
    history
    |> Enum.reverse()
    |> Enum.find(fn entry ->
      entry.role == "checker" and entry.status == "completed" and Map.has_key?(entry, :verdict)
    end)
  end

  defp final_outcome?(nil, _loop_record), do: false

  defp final_outcome?(%{verdict: "pass"}, _loop_record), do: true

  defp final_outcome?(_final_verdict, %{status: status})
       when status in [:passed, :failed],
       do: true

  defp final_outcome?(_final_verdict, %{
         current_attempt: current_attempt,
         max_attempts: max_attempts
       })
       when is_integer(current_attempt) and is_integer(max_attempts),
       do: current_attempt >= max_attempts

  defp final_outcome?(_final_verdict, _loop_record), do: false

  defp step_history(history) do
    history
    |> Enum.reject(fn entry -> entry.status == "handoff_invalid" end)
    |> Enum.sort_by(&step_history_sort_key/1)
  end

  defp assign_terminal_run(socket) do
    history = socket.assigns[:step_history] || []
    attempt = socket.assigns[:attempt] || 1
    stage = socket.assigns[:stage] || "maker"
    selected_step = selected_step(history, socket.assigns[:selected_step_id])
    current_step_id = socket.assigns[:current_step_id]

    {key, scrollback_terminal_id} =
      terminal_run_identity(selected_step, socket.assigns.loop_id, attempt, stage)

    stream_loop_id =
      terminal_stream_loop_id(selected_step, current_step_id, socket.assigns.loop_id)

    socket
    |> assign(:terminal_run_key, key)
    |> assign(:selected_terminal_id, scrollback_terminal_id)
    |> assign(:terminal_stream_loop_id, stream_loop_id)
  end

  defp assign_terminal_ws_access(socket) do
    terminal_ws_url = Application.get_env(:algedonia, :terminal_ws_base_url)

    stream_loop_id = socket.assigns[:terminal_stream_loop_id]

    token =
      case {socket.assigns[:current_user], stream_loop_id} do
        {%{id: user_id}, loop_id} when is_binary(loop_id) and loop_id != "" ->
          TerminalAccessToken.sign(user_id, loop_id)

        _ ->
          nil
      end

    socket
    |> assign(:terminal_ws_url, terminal_ws_url)
    |> assign(:terminal_ws_token, token)
  end

  defp terminal_run_identity(nil, loop_id, attempt, stage) do
    {"attempt-#{attempt}-#{stage}", loop_id}
  end

  defp terminal_run_identity(entry, _loop_id, _attempt, _stage) do
    {"attempt-#{entry.attempt}-#{entry.role}-#{entry.id}", entry.id}
  end

  defp terminal_stream_loop_id(nil, _current_step_id, loop_id), do: loop_id

  defp terminal_stream_loop_id(entry, current_step_id, loop_id) do
    if entry.id == current_step_id do
      loop_id
    else
      nil
    end
  end

  defp resolve_daemon(socket) do
    case socket.assigns[:loop_record] do
      %{assigned_daemon_id: daemon_id} when is_binary(daemon_id) ->
        case Daemons.get_daemon(daemon_id) do
          %{status: :online} = daemon -> {:ok, daemon}
          _ -> Daemons.find_online()
        end

      _ ->
        Daemons.find_online()
    end
  end

  defp following_current_step?(socket) do
    selected = socket.assigns[:selected_step_id]
    current = socket.assigns[:current_step_id]

    is_nil(selected) or selected == current
  end

  defp selected_step(history, selected_step_id) do
    Enum.find(history, &(&1.id == selected_step_id))
  end

  defp selected_step_id([], _selected, _current_step_id), do: nil

  defp selected_step_id(history, selected, current_step_id) do
    cond do
      is_binary(selected) && Enum.any?(history, &(&1.id == selected)) ->
        selected

      is_binary(current_step_id) && Enum.any?(history, &(&1.id == current_step_id)) ->
        current_step_id

      true ->
        history |> List.last() |> Map.get(:id)
    end
  end

  defp current_step_id(_socket, []), do: nil

  defp current_step_id(socket, history) do
    loop_id = socket.assigns.loop_id

    cond do
      current = current_step_id_from_history_status(history) ->
        current.id

      current_id = Orchestrator.current_step_terminal_id(loop_id) ->
        if Enum.any?(history, &(&1.id == current_id)), do: current_id

      current_id = current_step_id_from_loop_context(socket, history) ->
        current_id

      latest_id = Orchestrator.latest_step_terminal_id(loop_id) ->
        if Enum.any?(history, &(&1.id == latest_id)), do: latest_id

      true ->
        history |> List.last() |> Map.get(:id)
    end
  end

  defp current_step_id_from_history_status(history) do
    Enum.find(history, fn entry -> entry.status == "running" end)
  end

  defp current_step_id_from_loop_context(socket, history) do
    stage = socket.assigns[:stage]
    attempt = socket.assigns[:attempt]

    role =
      case stage do
        "maker" -> "maker"
        "checker" -> "checker"
        _ -> nil
      end

    if is_integer(attempt) && is_binary(role) do
      history
      |> Enum.find(fn entry -> entry.attempt == attempt && entry.role == role end)
      |> case do
        nil -> nil
        entry -> entry.id
      end
    end
  end

  defp step_history_sort_key(entry) do
    role_order = if entry.role == "maker", do: 0, else: 1
    timestamp_order = entry |> Map.get(:started_at) |> sortable_timestamp()

    {
      Map.get(entry, :attempt, 0),
      role_order,
      timestamp_order,
      Map.get(entry, :id, "")
    }
  end

  defp sortable_timestamp(nil), do: 0

  defp sortable_timestamp(%DateTime{} = timestamp) do
    DateTime.to_unix(timestamp, :microsecond)
  end

  defp sortable_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.to_unix(parsed, :microsecond)
      _ -> 0
    end
  end

  defp sortable_timestamp(_), do: 0
end
