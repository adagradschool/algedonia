defmodule AlgedoniaWeb.LoopLive.Show do
  @moduledoc """
  LiveView for inspecting a loop's terminal output in real-time.
  """
  use AlgedoniaWeb, :live_view

  alias Algedonia.{Agents, Loops, TaskLoopOrchestrator, Terminals, Tickets}
  alias AlgedoniaWeb.DaemonChannel

  alias AlgedoniaWeb.LoopLive.{
    ContextHelper,
    DiffTab,
    HistoryHelper,
    OverviewHelper,
    TerminalHelper
  }

  alias AlgedoniaWeb.Markdown
  import AlgedoniaWeb.LoopComponents
  import AlgedoniaWeb.CommentComponents, only: [avatar: 1, relative_time: 1]
  import AlgedoniaWeb.DiffComponents

  @impl true
  def mount(
        %{"loop_ref" => loop_ref, "workspace" => workspace_slug} = params,
        _session,
        socket
      ) do
    loop_id = ContextHelper.resolve_loop_id(loop_ref)

    socket = assign(socket, :route_ticket_ref, params["ticket_ref"])
    socket = ContextHelper.assign_loop_context(socket, loop_id)

    if connected?(socket) do
      Terminals.subscribe(loop_id)
      ContextHelper.maybe_subscribe_loop_updates(loop_id)
      ContextHelper.maybe_subscribe_ticket_updates(socket)
    end

    agent_type = Agents.ticket_agent_type(socket.assigns[:ticket])

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
      |> assign(init_agent_ui(agent_type))
      |> assign(:show_shortcut_help, false)
      |> assign(:planning_session?, false)
      |> assign(:comments, list_ticket_comments(socket.assigns[:ticket]))
      |> OverviewHelper.init_assigns()
      |> DiffTab.init_assigns()
      |> HistoryHelper.assign_history(TaskLoopOrchestrator.get_loop_history(loop_id))
      |> TerminalHelper.assign_terminal_run()
      |> TerminalHelper.assign_terminal_ws_access()

    if connected?(socket) do
      send(self(), {:send_scrollback, socket.assigns.selected_terminal_id})
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    role = params["role"] || socket.assigns.role

    planning? = ContextHelper.planning_session?(role)
    prefix = ContextHelper.workspace_prefix(socket)

    page_title =
      ContextHelper.build_page_title(
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

  def handle_event("switch_tab", %{"tab" => tab}, socket)
      when tab in ["overview", "rubric"] do
    socket =
      if socket.assigns.active_tab == "diff", do: DiffTab.on_tab_leave(socket), else: socket

    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("switch_tab", %{"tab" => "diff"}, socket) do
    {:noreply, DiffTab.on_tab_enter(socket)}
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
      |> TerminalHelper.assign_terminal_run()
      |> TerminalHelper.assign_terminal_ws_access()

    if connected?(socket) do
      send(self(), {:send_scrollback, socket.assigns.selected_terminal_id})
    end

    {:noreply, socket}
  end

  def handle_event("toggle_shortcut_help", _params, socket) do
    {:noreply, assign(socket, :show_shortcut_help, !socket.assigns.show_shortcut_help)}
  end

  def handle_event("terminal_request_scrollback", _params, socket) do
    if connected?(socket) do
      send(self(), {:send_scrollback, socket.assigns.selected_terminal_id})
    end

    {:noreply, socket}
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

  def handle_event("refresh_diff", _params, socket) do
    {:noreply, DiffTab.handle_refresh(socket)}
  end

  def handle_event("open_inline_comment", params, socket) do
    {:noreply, assign(socket, :inline_comment_form, params)}
  end

  def handle_event("close_inline_comment", _params, socket) do
    {:noreply, assign(socket, :inline_comment_form, nil)}
  end

  def handle_event("add_inline_comment", params, socket) do
    socket =
      socket
      |> DiffTab.handle_add_inline_comment(params)
      |> assign(:inline_comment_form, nil)

    {:noreply, socket}
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

  def handle_info(:diff_debounce_fire, socket) do
    {:noreply, DiffTab.handle_debounce_fire(socket)}
  end

  def handle_info(:poll_diff, socket) do
    {:noreply, DiffTab.handle_poll_tick(socket)}
  end

  def handle_info({:diff_result, diff_text, error}, socket) do
    {:noreply, DiffTab.handle_diff_result(socket, diff_text, error)}
  end

  def handle_info({:terminal_data, _loop_id, _data}, socket) do
    {:noreply, socket}
  end

  def handle_info({:terminal_ended, loop_id, exit_code}, socket) do
    cond do
      loop_id == socket.assigns.loop_id ->
        socket =
          socket
          |> push_event("terminal_ended", %{exit_code: exit_code})
          |> assign(:active, false)
          |> HistoryHelper.assign_history(
            TaskLoopOrchestrator.get_loop_history(socket.assigns.loop_id)
          )
          |> TerminalHelper.assign_terminal_run()
          |> TerminalHelper.assign_terminal_ws_access()

        {:noreply, socket}

      loop_id == socket.assigns.selected_terminal_id ->
        {:noreply, push_event(socket, "terminal_ended", %{exit_code: exit_code})}

      loop_id == socket.assigns.overview_job_id ->
        {:noreply, OverviewHelper.handle_overview_ended(socket, loop_id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:loop_updated, loop}, socket) do
    loop = Loops.preload_ticket(loop)
    stage = ContextHelper.stage_for_status(loop.status)
    attempt = max(loop.current_attempt, 1)
    prefix = ContextHelper.workspace_prefix(socket)

    page_title =
      ContextHelper.build_page_title(
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
     |> TerminalHelper.assign_terminal_run()
     |> TerminalHelper.assign_terminal_ws_access()}
  end

  def handle_info({:loop_history_updated, history}, socket) do
    previous_terminal_id = socket.assigns.selected_terminal_id
    was_following_current = HistoryHelper.following_current_step?(socket)

    socket =
      if was_following_current do
        assign(socket, :selected_step_id, nil)
      else
        socket
      end

    socket =
      socket
      |> HistoryHelper.assign_history(history)
      |> TerminalHelper.assign_terminal_run()
      |> TerminalHelper.assign_terminal_ws_access()

    if connected?(socket) && socket.assigns.selected_terminal_id != previous_terminal_id do
      send(self(), {:send_scrollback, socket.assigns.selected_terminal_id})
    end

    {:noreply, socket}
  end

  def handle_info({event, ticket}, socket) when event in [:ticket_updated] do
    if socket.assigns.ticket && socket.assigns.ticket.id == ticket.id do
      agent_type = Agents.ticket_agent_type(ticket)

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
    if HistoryHelper.final_outcome?(final_verdict, loop_record),
      do: "Final Verdict",
      else: "Checker Verdict"
  end

  def loop_show_path(workspace_slug, ticket, route_ticket_ref, loop_id) do
    ref = if ticket, do: ticket_ref(ticket), else: route_ticket_ref || "ad-hoc"

    ~p"/w/#{workspace_slug}/tickets/#{ref}/loops/#{short_id(loop_id)}"
  end

  # -- Private --

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
    case TaskLoopOrchestrator.start_task_loop(socket.assigns.loop_id, daemon_name,
           model: socket.assigns.selected_model,
           effort: socket.assigns.selected_effort,
           agent_type: socket.assigns.agent_type
         ) do
      :ok ->
        socket
        |> assign(:active, true)
        |> HistoryHelper.assign_history(
          TaskLoopOrchestrator.get_loop_history(socket.assigns.loop_id)
        )
        |> OverviewHelper.maybe_start_overview_generation()

      {:error, _} ->
        put_flash(socket, :error, "Unable to start loop")
    end
  end

  defp start_ad_hoc_loop(socket, daemon_name) do
    task = ContextHelper.ad_hoc_task(socket)

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
    |> OverviewHelper.maybe_start_overview_generation()
  end

  defp list_ticket_comments(%{id: id}), do: Tickets.list_comments(id)
  defp list_ticket_comments(_), do: []
end
