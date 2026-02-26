defmodule AlgedoniaWeb.LoopLive.Show do
  @moduledoc """
  LiveView for inspecting a loop's terminal output in real-time.
  """
  use AlgedoniaWeb, :live_view

  alias Algedonia.{Agents, Daemons, Loops, Orchestrator, Terminals, Tickets}
  alias AlgedoniaWeb.DaemonChannel
  alias AlgedoniaWeb.Markdown
  import AlgedoniaWeb.LoopComponents

  @status_to_stage %{
    running_checker: "checker",
    passed: "completed",
    failed: "failed"
  }
  @terminal_flush_interval_ms 16
  @chat_marker_start "[[ALGEDONIA_CHAT:"
  @chat_marker_end "]]"

  @impl true
  def mount(%{"loop_id" => loop_id, "workspace" => workspace_slug}, _session, socket) do
    if connected?(socket) do
      Terminals.subscribe(loop_id)
      maybe_subscribe_loop_updates(loop_id)
      maybe_subscribe_ticket_updates(loop_id)
      push_scrollback(loop_id)
    end

    socket = assign_loop_context(socket, loop_id)
    agent_type = default_agent_type(socket.assigns[:ticket])

    socket =
      socket
      |> assign(:loop_id, loop_id)
      |> assign(:workspace_slug, workspace_slug)
      |> assign(:active, Terminals.active?(loop_id))
      |> assign(:role, "maker")
      |> assign(:agent_type, agent_type)
      |> assign(:auto_start_requested, false)
      |> assign(:active_tab, "overview")
      |> assign(:overview_content, nil)
      |> assign(:overview_loading, false)
      |> assign(:overview_job_id, nil)
      |> assign(:terminal_pending_data, "")
      |> assign(:terminal_flush_scheduled, false)
      |> assign(init_agent_ui(agent_type))
      |> assign(:show_shortcut_help, false)
      |> assign(:page_title, "Loop #{loop_id}")
      |> assign_history(Orchestrator.get_loop_history(loop_id))

    socket =
      socket
      |> assign_terminal_run()

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

  def handle_event("set_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, apply_model_change(socket.assigns, model))}
  end

  def handle_event("set_effort", %{"effort" => effort}, socket) do
    {:noreply, assign(socket, apply_effort_change(socket.assigns, effort))}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
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

  def handle_event("terminal_input", %{"data" => data}, socket) do
    with {:ok, daemon} <- Daemons.find_online() do
      DaemonChannel.push_stdin_input(daemon.name, socket.assigns.loop_id, data)
    end

    {:noreply, socket}
  end

  def handle_event("send_agent_message", %{"agent_message" => %{"text" => text}}, socket) do
    trimmed = String.trim(text || "")

    socket =
      if trimmed != "" do
        data = Base.encode64(trimmed <> "\r")

        with {:ok, daemon} <- Daemons.find_online() do
          DaemonChannel.push_stdin_input(daemon.name, socket.assigns.loop_id, data)
        end

        push_event(socket, "composer_clear", %{})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("stop_loop", _params, socket) do
    with {:ok, daemon} <- Daemons.find_online() do
      DaemonChannel.push_stop_loop(daemon.name, socket.assigns.loop_id)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:auto_start_loop, socket) do
    {:noreply, start_loop_on_daemon(socket)}
  end

  @impl true
  def handle_info({:send_scrollback, scrollback}, socket) do
    encoded = Base.encode64(scrollback)
    {:noreply, push_event(socket, "terminal_scrollback", %{data: encoded})}
  end

  def handle_info(:flush_terminal_data, socket) do
    {:noreply, flush_pending_terminal_data(socket)}
  end

  def handle_info({:terminal_data, loop_id, data}, socket) do
    if loop_id == socket.assigns.loop_id do
      socket =
        socket
        |> enqueue_terminal_data(data)
        |> maybe_ingest_chat_data(data)

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
          |> flush_pending_terminal_data()
          |> push_event("terminal_ended", %{exit_code: exit_code})
          |> assign(:active, false)
          |> assign_history(Orchestrator.get_loop_history(socket.assigns.loop_id))

        {:noreply, socket}

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
     |> assign_terminal_run()}
  end

  def handle_info({:loop_history_updated, history}, socket) do
    {:noreply,
     socket
     |> assign_history(history)
     |> assign_terminal_run()}
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

  defp start_loop_on_daemon(socket) do
    case Daemons.find_online() do
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
    loop = if uuid?(loop_id), do: Loops.get_loop(loop_id), else: nil

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
    if uuid?(loop_id), do: Loops.subscribe(loop_id)
  end

  defp maybe_subscribe_ticket_updates(loop_id) do
    if uuid?(loop_id) do
      with %{} = loop <- Loops.get_loop(loop_id),
           loop <- Loops.preload_ticket(loop) do
        Tickets.subscribe()
        Tickets.subscribe_comments(loop.dag.ticket_id)
      end
    end
  end

  defp push_scrollback(loop_id) do
    scrollback = Terminals.get_scrollback(loop_id)
    if scrollback != "", do: send(self(), {:send_scrollback, scrollback})
  end

  defp uuid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp uuid?(_), do: false

  defp assign_history(socket, history) do
    socket
    |> assign(:history, history)
    |> assign(:visible_history, visible_history(history))
    |> assign(:final_verdict, extract_final_verdict(history))
  end

  defp extract_final_verdict(history) do
    history
    |> Enum.reverse()
    |> Enum.find(fn entry ->
      entry.role == "checker" and entry.status == "completed" and Map.has_key?(entry, :verdict)
    end)
  end

  defp visible_history(history) do
    Enum.reject(history, fn entry -> entry.status == "handoff_invalid" end)
  end

  defp assign_terminal_run(socket) do
    history = socket.assigns[:history] || []
    attempt = socket.assigns[:attempt] || 1
    stage = socket.assigns[:stage] || "maker"
    running_entry = current_running_history(history)
    previous_key = socket.assigns[:terminal_run_key]
    {key, label} = terminal_run_identity(running_entry, attempt, stage)

    socket =
      socket
      |> assign(:terminal_run_key, key)
      |> assign(:terminal_run_label, label)

    maybe_reset_chat_state(socket, previous_key, key)
  end

  defp terminal_run_identity(nil, attempt, stage) do
    {"attempt-#{attempt}-#{stage}", "Attempt #{attempt} \u00b7 #{String.upcase(stage)}"}
  end

  defp terminal_run_identity(entry, _attempt, _stage) do
    {"attempt-#{entry.attempt}-#{entry.role}-#{entry.id}",
     "Attempt #{entry.attempt} \u00b7 #{String.upcase(entry.role)}"}
  end

  defp maybe_reset_chat_state(socket, previous_key, key)
       when previous_key != nil and previous_key != key do
    socket
    |> assign(:chat_messages, [])
    |> assign(:chat_buffer, "")
    |> assign(:chat_split_pending, false)
    |> assign(:terminal_pending_data, "")
    |> assign(:terminal_flush_scheduled, false)
  end

  defp maybe_reset_chat_state(socket, _previous_key, _key), do: socket

  defp enqueue_terminal_data(socket, data) do
    pending = (socket.assigns[:terminal_pending_data] || "") <> data
    socket = assign(socket, :terminal_pending_data, pending)

    if socket.assigns[:terminal_flush_scheduled] do
      socket
    else
      Process.send_after(self(), :flush_terminal_data, @terminal_flush_interval_ms)
      assign(socket, :terminal_flush_scheduled, true)
    end
  end

  defp flush_pending_terminal_data(socket) do
    pending = socket.assigns[:terminal_pending_data] || ""

    socket =
      socket
      |> assign(:terminal_pending_data, "")
      |> assign(:terminal_flush_scheduled, false)

    if pending == "" do
      socket
    else
      encoded = Base.encode64(pending)
      push_event(socket, "terminal_data", %{data: encoded})
    end
  end

  defp current_running_history(history) do
    history
    |> Enum.reverse()
    |> Enum.find(fn entry -> entry.status == "running" end)
  end

  defp ingest_chat_data(socket, data) do
    text = (socket.assigns.chat_buffer || "") <> to_string(data)
    {socket, rest} = consume_chat_markers(socket, text)
    assign(socket, :chat_buffer, String.slice(rest, max(String.length(rest) - 256, 0), 256))
  end

  defp consume_chat_markers(socket, text) do
    case :binary.match(text, @chat_marker_start) do
      :nomatch ->
        {socket, text}

      {start_idx, _} ->
        sliced = binary_part(text, start_idx, byte_size(text) - start_idx)
        after_start_idx = byte_size(@chat_marker_start)

        case :binary.match(
               binary_part(sliced, after_start_idx, byte_size(sliced) - after_start_idx),
               @chat_marker_end
             ) do
          :nomatch ->
            {socket, sliced}

          {end_rel_idx, _} ->
            payload_b64 = binary_part(sliced, after_start_idx, end_rel_idx)
            rest_start = after_start_idx + end_rel_idx + byte_size(@chat_marker_end)
            rest = binary_part(sliced, rest_start, byte_size(sliced) - rest_start)
            socket = apply_chat_marker(socket, payload_b64)
            consume_chat_markers(socket, rest)
        end
    end
  end

  defp apply_chat_marker(socket, payload_b64) do
    with {:ok, decoded} <- Base.decode64(payload_b64),
         {:ok, payload} <- Jason.decode(decoded),
         kind when is_binary(kind) <- payload["kind"],
         delta when is_binary(delta) <- payload["delta"] do
      case kind do
        "user" -> append_chat_message(socket, "user", "user", delta, merge: true)
        "agent" -> append_chat_message(socket, "agent", "agent", delta, merge: true)
        "reasoning" -> append_chat_message(socket, "agent", "reasoning", delta, merge: true)
        "command" -> append_chat_message(socket, "agent", "command", delta, merge: true)
        _ -> socket
      end
    else
      _ -> socket
    end
  end

  defp append_chat_message(socket, role, kind, text, opts) do
    trimmed = String.replace(text, ~r/\r/u, "")
    if trimmed == "", do: socket, else: do_append_chat_message(socket, role, kind, trimmed, opts)
  end

  defp do_append_chat_message(socket, role, kind, text, opts) do
    messages = socket.assigns.chat_messages || []
    merge = Keyword.get(opts, :merge, false)

    updated =
      case List.last(messages) do
        %{role: ^role, kind: ^kind, text: prev} when merge ->
          List.replace_at(messages, length(messages) - 1, %{
            role: role,
            kind: kind,
            text: prev <> text
          })

        _ ->
          messages ++
            [%{id: System.unique_integer([:positive]), role: role, kind: kind, text: text}]
      end

    socket
    |> assign(:chat_messages, Enum.take(updated, -200))
  end

  defp maybe_ingest_chat_data(socket, data) do
    if socket.assigns.agent_type == "claude_code" do
      socket
    else
      ingest_chat_data(socket, data)
    end
  end
end
