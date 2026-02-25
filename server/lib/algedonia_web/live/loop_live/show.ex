defmodule AlgedoniaWeb.LoopLive.Show do
  @moduledoc """
  LiveView for inspecting a loop's terminal output in real-time.
  """
  use AlgedoniaWeb, :live_view

  alias Algedonia.{Daemons, Loops, Orchestrator, Repo, Terminals, Tickets}
  alias AlgedoniaWeb.DaemonChannel
  alias AlgedoniaWeb.Markdown

  @status_to_stage %{
    running_checker: "checker",
    passed: "checker",
    failed: "checker"
  }

  @impl true
  def mount(%{"loop_id" => loop_id, "workspace" => workspace_slug}, _session, socket) do
    if connected?(socket) do
      Terminals.subscribe(loop_id)
      maybe_subscribe_loop_updates(loop_id)
      maybe_subscribe_ticket_updates(loop_id)
      push_scrollback(loop_id)
    end

    socket =
      socket
      |> assign_loop_context(loop_id)
      |> assign(:loop_id, loop_id)
      |> assign(:workspace_slug, workspace_slug)
      |> assign(:active, Terminals.active?(loop_id))
      |> assign(:role, "maker")
      |> assign(:agent_type, nil)
      |> assign(:auto_start_requested, false)
      |> assign(:active_tab, "overview")
      |> assign(:overview_content, nil)
      |> assign(:overview_loading, false)
      |> assign(:overview_job_id, nil)
      |> assign(:page_title, "Loop #{loop_id}")
      |> assign(:history, Orchestrator.get_loop_history(loop_id))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    role = params["role"] || socket.assigns.role

    socket =
      socket
      |> assign(:role, role)
      |> assign(:agent_type, params["agent_type"])

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

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
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
    daemons = Daemons.list_daemons()
    online = Enum.find(daemons, &(&1.status == :online))

    if online do
      DaemonChannel.push_stdin_input(online.name, socket.assigns.loop_id, data)
    end

    {:noreply, socket}
  end

  def handle_event("stop_loop", _params, socket) do
    daemons = Daemons.list_daemons()
    online = Enum.find(daemons, &(&1.status == :online))

    if online do
      DaemonChannel.push_stop_loop(online.name, socket.assigns.loop_id)
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

  def handle_info({:terminal_data, loop_id, data}, socket) do
    if loop_id == socket.assigns.loop_id do
      encoded = Base.encode64(data)
      {:noreply, push_event(socket, "terminal_data", %{data: encoded})}
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
          |> assign(:history, Orchestrator.get_loop_history(socket.assigns.loop_id))

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
    loop = Repo.preload(loop, dag: :ticket)

    {:noreply,
     socket
     |> assign(:loop_record, loop)
     |> assign(:ticket, loop.dag.ticket)
     |> assign(:loop_title, loop.title)
     |> assign(:stage, Map.get(@status_to_stage, loop.status, "maker"))
     |> assign(:attempt, max(loop.current_attempt, 1))
     |> assign(:rubric, loop.rubric || loop.dag.ticket.rubric || "")}
  end

  def handle_info({:loop_history_updated, history}, socket) do
    {:noreply, assign(socket, :history, history)}
  end

  def handle_info({event, ticket}, socket) when event in [:ticket_updated] do
    if socket.assigns.ticket && socket.assigns.ticket.id == ticket.id do
      {:noreply,
       socket
       |> assign(:ticket, ticket)
       |> assign(:acceptance_criteria, ticket.acceptance_criteria || "")}
    else
      {:noreply, socket}
    end
  end

  def render_markdown(text), do: Markdown.render(text)

  defp start_loop_on_daemon(socket) do
    daemons = Daemons.list_daemons()
    online = Enum.find(daemons, &(&1.status == :online))

    case online do
      nil ->
        put_flash(socket, :error, "No online daemon available")

      daemon ->
        if socket.assigns.loop_record do
          start_persisted_loop(socket, daemon.name)
        else
          start_ad_hoc_loop(socket, daemon.name)
        end
    end
  end

  defp start_persisted_loop(socket, daemon_name) do
    case Orchestrator.start_task_loop(socket.assigns.loop_id, daemon_name) do
      :ok ->
        socket
        |> assign(:active, true)
        |> assign(:history, Orchestrator.get_loop_history(socket.assigns.loop_id))
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
        daemons = Daemons.list_daemons()
        online = Enum.find(daemons, &(&1.status == :online))

        if online == nil do
          socket
        else
          job_id = "overview-#{socket.assigns.loop_id}-#{System.unique_integer([:positive])}"
          Terminals.subscribe(job_id)

          DaemonChannel.push_start_loop(online.name, job_id, %{
            "role" => "overview",
            "agent_type" => "codex",
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
    Summarize this loop context for an Overview tab in natural language markdown.

    Ticket title: #{ticket.title}
    Ticket description:
    #{ticket.description || "(none)"}

    Acceptance criteria:
    #{ticket.acceptance_criteria || "(none)"}

    Loop title: #{loop.title}
    Loop task:
    #{loop.description || "(none)"}

    Rubric:
    #{socket.assigns.rubric || "(none)"}

    Output markdown with sections:
    - Goal
    - Acceptance Criteria (bullet list)
    - Current Status
    - Final Result (natural language summary)
    """
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
        loop = Repo.preload(loop, dag: :ticket)
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
           loop <- Repo.preload(loop, dag: :ticket) do
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
end
