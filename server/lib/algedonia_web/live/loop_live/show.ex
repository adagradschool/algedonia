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
  import AlgedoniaWeb.CommentComponents, only: [avatar: 1, relative_time: 1]

  @status_to_stage %{
    running_checker: "checker",
    passed: "completed",
    failed: "failed"
  }

  @planning_workflow_instructions """
  Planning workflow:
  1. Read the repository context before asking questions.
  2. Ask the user one clarifying question at a time and wait for a response.
  3. Once the user approves, post the final implementation plan as a ticket comment.
  4. Always update the ticket title, description, acceptance criteria, and rubric to match the approved plan.
  5. Before writing the updated rubric, consult notes/rubrics.md and align the rubric with repository standards.

  Required AG CLI commands (run these, do not just describe them):
  - Add plan comment:
    ag ticket comment ~TICKET_REF --author "planner" --body "<final plan markdown>"
  - Update ticket fields:
    ag ticket update ~TICKET_REF --title "<title>" --description "<description>" --acceptance-criteria "<acceptance criteria>" --rubric "<rubric>"
  - Fetch existing comments when needed:
    ag ticket comments ~TICKET_REF --json

  Do not implement code in this planning session.
  """

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
      maybe_subscribe_ticket_updates(socket, loop_id)
    end

    socket = assign(socket, :route_ticket_ref, params["ticket_ref"])
    socket = assign_loop_context(socket, loop_id)
    agent_type = default_agent_type(socket.assigns[:ticket])

    socket =
      socket
      |> assign(:loop_id, loop_id)
      |> assign(:loop_ref, loop_ref)
      |> assign(:workspace_slug, workspace_slug)
      |> assign(:active, Terminals.active?(loop_id))
      |> assign(:role, "maker")
      |> assign(:agent_type, agent_type)
      |> assign(:auto_start_requested, false)
      |> assign(:show_steps, false)
      |> assign(:active_tab, "overview")
      |> assign(:overview_content, overview_from_ticket(socket.assigns[:ticket]))
      |> assign(:overview_loading, false)
      |> assign(:overview_job_id, nil)
      |> assign(init_agent_ui(agent_type))
      |> assign(:show_shortcut_help, false)
      |> assign(:planning_session?, false)
      |> assign(:comments, list_ticket_comments(socket.assigns[:ticket]))
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

    planning? = planning_session?(role)
    prefix = workspace_prefix(socket)

    page_title =
      build_page_title(
        socket.assigns[:ticket],
        prefix,
        socket.assigns.stage,
        socket.assigns.attempt,
        planning?
      ) || socket.assigns.page_title

    socket =
      socket
      |> assign(:role, role)
      |> assign(:planning_session?, planning?)
      |> assign(:page_title, page_title)
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

  def handle_event("finish_planning", _params, socket) do
    with {:ok, daemon} <- resolve_daemon(socket) do
      DaemonChannel.push_stop_loop(daemon.name, socket.assigns.loop_id)
    end

    ticket_ref = ticket_ref(socket.assigns.ticket)
    path = ~p"/w/#{socket.assigns.workspace_slug}/tickets/#{ticket_ref}"
    {:noreply, push_navigate(socket, to: path)}
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
        persist_overview(socket.assigns.ticket, overview)

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
    stage = Map.get(@status_to_stage, loop.status, "maker")
    attempt = max(loop.current_attempt, 1)
    prefix = workspace_prefix(socket)

    page_title =
      build_page_title(
        loop.dag.ticket,
        prefix,
        stage,
        attempt,
        socket.assigns.planning_session?
      ) || socket.assigns.page_title

    {:noreply,
     socket
     |> assign(:loop_record, loop)
     |> assign(:ticket, loop.dag.ticket)
     |> assign(:loop_title, loop.title)
     |> assign(:stage, stage)
     |> assign(:attempt, attempt)
     |> assign(:page_title, page_title)
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

  def handle_info({event, _comment}, socket)
      when event in [:comment_created, :comment_updated, :comment_deleted] do
    {:noreply, assign(socket, :comments, list_ticket_comments(socket.assigns.ticket))}
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
    task = ad_hoc_task(socket)

    opts =
      %{}
      |> maybe_put("role", socket.assigns[:role])
      |> maybe_put("agent_type", socket.assigns[:agent_type])
      |> maybe_put("model", socket.assigns[:selected_model])
      |> maybe_put("effort", socket.assigns[:selected_effort])
      |> maybe_put("task", task)

    DaemonChannel.push_start_loop(daemon_name, socket.assigns.loop_id, opts)

    socket
    |> assign(:active, true)
    |> maybe_start_overview_generation()
  end

  defp maybe_start_overview_generation(socket) do
    cond do
      socket.assigns.ticket == nil ->
        socket

      socket.assigns.ticket.overview != nil ->
        assign(socket, :overview_content, socket.assigns.ticket.overview)

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
        ticket = ticket_for_route(socket)

        socket
        |> assign(:loop_record, nil)
        |> assign(:ticket, ticket)
        |> assign(:loop_title, ad_hoc_loop_title(ticket))
        |> assign(:stage, "maker")
        |> assign(:attempt, 1)
        |> assign(:rubric, "")
        |> assign(
          :acceptance_criteria,
          if(ticket, do: ticket.acceptance_criteria || "", else: "")
        )
        |> assign(:page_title, "Loop #{display_loop_id(loop_id)}")

      loop ->
        loop = Loops.preload_ticket(loop)
        ticket = loop.dag.ticket
        stage = Map.get(@status_to_stage, loop.status, "maker")
        attempt = max(loop.current_attempt, 1)

        socket
        |> assign(:loop_record, loop)
        |> assign(:ticket, ticket)
        |> assign(:loop_title, loop.title)
        |> assign(:stage, stage)
        |> assign(:attempt, attempt)
        |> assign(:rubric, loop.rubric || ticket.rubric || "")
        |> assign(:acceptance_criteria, ticket.acceptance_criteria || "")
        |> assign(:page_title, "Loop #{display_loop_id(loop_id)}")
    end
  end

  defp maybe_subscribe_loop_updates(loop_id) do
    case Loops.get_loop_by_ref(loop_id) do
      nil -> :ok
      loop -> Loops.subscribe(loop.id)
    end
  end

  defp maybe_subscribe_ticket_updates(socket, loop_id) do
    ticket_id =
      case Loops.get_loop_by_ref(loop_id) do
        %{} = loop ->
          loop = Loops.preload_ticket(loop)
          loop.dag.ticket_id

        nil ->
          case ticket_for_route(socket) do
            %{id: id} -> id
            _ -> nil
          end
      end

    if ticket_id do
      Tickets.subscribe()
      Tickets.subscribe_comments(ticket_id)
    end
  end

  defp resolve_loop_id(loop_ref) do
    case Loops.get_loop_by_ref(loop_ref) do
      nil -> loop_ref
      loop -> loop.id
    end
  end

  defp ad_hoc_task(%{assigns: %{role: "planning", ticket: ticket}}) when not is_nil(ticket) do
    ticket_ref =
      if is_integer(ticket.number), do: Integer.to_string(ticket.number), else: ticket.id

    instructions = String.replace(@planning_workflow_instructions, "~TICKET_REF", ticket_ref)

    [
      "Ticket: #{ticket.title}",
      optional_ad_hoc_section("Description", ticket.description),
      optional_ad_hoc_section("Acceptance criteria", ticket.acceptance_criteria),
      optional_ad_hoc_section("Current rubric", ticket.rubric),
      instructions
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp ad_hoc_task(_socket), do: nil

  defp optional_ad_hoc_section(_label, nil), do: nil
  defp optional_ad_hoc_section(_label, ""), do: nil
  defp optional_ad_hoc_section(label, body), do: "#{label}:\n#{body}"

  defp ticket_for_route(socket) do
    with %{} = workspace <- socket.assigns[:current_workspace],
         ticket_ref when is_binary(ticket_ref) <- socket.assigns[:route_ticket_ref],
         true <- ticket_ref_reference?(ticket_ref) do
      Tickets.get_ticket_by_ref!(workspace.id, ticket_ref)
    else
      _ -> nil
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp ticket_ref_reference?(ticket_ref) do
    case Integer.parse(ticket_ref) do
      {_, ""} ->
        true

      _ ->
        match?({:ok, _}, Ecto.UUID.cast(ticket_ref))
    end
  end

  defp ad_hoc_loop_title(nil), do: "Ad hoc loop"
  defp ad_hoc_loop_title(ticket), do: "Planning: #{ticket.title}"

  defp planning_session?(role), do: role == "planning"

  defp build_page_title(ticket, workspace_prefix, stage, attempt, planning?)

  defp build_page_title(%{number: number}, prefix, _stage, _attempt, true)
       when is_integer(number) and is_binary(prefix) do
    "#{prefix}-#{number}"
  end

  defp build_page_title(%{number: number}, prefix, stage, attempt, false)
       when is_integer(number) and is_binary(prefix) do
    "#{prefix}-#{number} · #{String.capitalize(stage)} ##{attempt}"
  end

  defp build_page_title(_ticket, _prefix, _stage, _attempt, _planning?) do
    nil
  end

  def loop_show_path(workspace_slug, ticket, route_ticket_ref, loop_id) do
    ticket_ref = if ticket, do: ticket_ref(ticket), else: route_ticket_ref || "ad-hoc"

    ~p"/w/#{workspace_slug}/tickets/#{ticket_ref}/loops/#{String.slice(loop_id, 0, 8)}"
  end

  defp ticket_ref(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  defp ticket_ref(%{id: id}), do: id

  defp display_loop_id(loop_id), do: String.slice(loop_id, 0, 8)

  defp workspace_prefix(socket) do
    case socket.assigns[:current_workspace] do
      %{prefix: prefix} -> prefix
      _ -> nil
    end
  end

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

  defp list_ticket_comments(%{id: id}), do: Tickets.list_comments(id)
  defp list_ticket_comments(_), do: []

  defp overview_from_ticket(%{overview: overview}) when is_binary(overview), do: overview
  defp overview_from_ticket(_), do: nil

  defp persist_overview(%{id: _} = ticket, content) when is_binary(content) do
    Tickets.update_overview(ticket, content)
  end

  defp persist_overview(_, _), do: :ok
end
