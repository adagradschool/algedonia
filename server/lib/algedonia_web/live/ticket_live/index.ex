defmodule AlgedoniaWeb.TicketLive.Index do
  @moduledoc """
  LiveView for ticket listing — board and list views with detail panel.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  alias Algedonia.{Dags, Tickets}
  alias Algedonia.Tickets.Ticket
  alias Algedonia.Workspaces
  alias AlgedoniaWeb.TicketLive.DetailEvents

  import AlgedoniaWeb.TicketComponents
  import AlgedoniaWeb.PresenceComponents
  import AlgedoniaWeb.TicketLive.FilterHelpers

  @statuses Tickets.display_statuses()

  @detail_events ~w(autosave_ticket autosave_ticket_markdown
    submit_comment submit_reply start_reply edit_comment update_comment
    cancel_edit delete_comment start_work plan_ticket open_planning_session
    export_markdown duplicate_ticket confirm_delete cancel_delete confirm_delete_now)

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: Tickets.subscribe()
    workspace_slug = params["workspace"] || session["current_workspace_slug"]

    current_workspace =
      socket.assigns[:current_workspace] ||
        (session["current_workspace_id"] &&
           Workspaces.get_workspace!(session["current_workspace_id"]))

    {:ok,
     assign(socket,
       statuses: @statuses,
       show_shortcut_help: false,
       current_user_id: session["user_id"],
       current_workspace_id: session["current_workspace_id"],
       current_workspace: current_workspace,
       workspace_prefix: session["current_workspace_prefix"] || "AG",
       workspace_slug: workspace_slug,
       save_state: :idle,
       confirm_delete: false,
       delete_ticket_id: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filter_state = filter_state_from_params(params)
    filters_changed? = filters_changed?(socket.assigns, filter_state)
    socket = assign(socket, filter_state)
    prior_action = socket.assigns[:last_live_action]

    socket =
      if filters_changed? || prior_action == :show,
        do: stream_tickets(socket),
        else: socket

    {:noreply,
     socket
     |> assign(:last_live_action, socket.assigns.live_action)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params),
    do: assign(socket, page_title: "Tickets", ticket: nil)

  defp apply_action(socket, :new, params) do
    assign(socket,
      page_title: "New Ticket",
      ticket: %Ticket{status: parse_status(params["status"]) || :backlog}
    )
  end

  defp apply_action(socket, :show, %{"ticket_ref" => ref}) do
    DetailEvents.load_detail(socket, socket.assigns.current_workspace.id, ref)
  end

  defp apply_action(socket, :edit, %{"ticket_ref" => ticket_ref}) do
    ticket = Tickets.get_ticket_by_ref!(socket.assigns.current_workspace.id, ticket_ref)
    assign(socket, page_title: "Edit Ticket", ticket: ticket)
  end

  # -- Board / list events --

  @impl true
  def handle_event("toggle_view", %{"view" => view}, socket) do
    {:noreply, push_patch(socket, to: tickets_path(socket, view: view))}
  end

  def handle_event("toggle_view_shortcut", _p, socket) do
    view = if socket.assigns.view_mode == :list, do: "board", else: "list"
    {:noreply, push_patch(socket, to: tickets_path(socket, view: view))}
  end

  def handle_event("toggle_shortcut_help", _p, socket) do
    {:noreply, assign(socket, :show_shortcut_help, !socket.assigns.show_shortcut_help)}
  end

  def handle_event("shortcut_back", _p, socket) do
    if socket.assigns.live_action == :show,
      do: {:noreply, push_patch(socket, to: tickets_path(socket))},
      else: {:noreply, socket}
  end

  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: tickets_path(socket, status: status))}
  end

  def handle_event("sort", %{"sort_by" => sort_by}, socket) do
    {:noreply, push_patch(socket, to: tickets_path(socket, sort_by: sort_by))}
  end

  def handle_event("clear_filters", _p, socket) do
    view = if socket.assigns.view_mode == :list, do: "list", else: "board"

    {:noreply,
     push_patch(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets?#{%{view: view}}")}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: tickets_path(socket, q: query))}
  end

  def handle_event("move_ticket", %{"id" => id, "status" => status}, socket) do
    ticket = Tickets.get_ticket!(id)
    _ = Tickets.update_ticket(ticket, %{status: parse_status(status) || ticket.status})
    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = Tickets.delete_ticket(Tickets.get_ticket!(id))

    {:noreply,
     socket |> put_flash(:info, "Ticket deleted") |> push_patch(to: tickets_path(socket))}
  end

  # -- Detail events (delegated) --

  def handle_event(event, params, socket) when event in @detail_events do
    DetailEvents.handle(event, params, socket)
  end

  # -- PubSub --

  @impl true
  def handle_info({event, _ticket}, socket)
      when event in [:ticket_created, :ticket_updated, :ticket_deleted] do
    {:noreply, stream_tickets(socket)}
  end

  def handle_info({event, _comment}, socket)
      when event in [:comment_created, :comment_updated, :comment_deleted] do
    ticket = socket.assigns[:ticket]

    if ticket,
      do: {:noreply, assign(socket, comments: Tickets.list_comments(ticket.id))},
      else: {:noreply, socket}
  end

  def handle_info({event, _loop}, socket)
      when event in [:hook_loop_created, :loop_status_changed] do
    ticket = socket.assigns[:ticket]

    if ticket,
      do:
        {:noreply,
         assign(socket, hook_loops: Algedonia.Loops.list_hook_loops_for_ticket(ticket.id))},
      else: {:noreply, socket}
  end

  def handle_info({:dag_created, _dag}, socket), do: {:noreply, socket}
  def handle_info({:dag_updated, _dag}, socket), do: {:noreply, socket}

  # -- Streams --

  defp stream_tickets(socket) do
    a = socket.assigns

    %{grouped: grouped, count: count} =
      Tickets.search_tickets_grouped(
        status: a.filter_status,
        assignee: a.filter_assignee,
        sort_by: a.sort_by,
        sort_order: a.sort_order,
        workspace_id: a.current_workspace_id,
        query: a.filter_query,
        prefix: a.workspace_prefix
      )

    ticket_ids =
      grouped
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)

    Enum.reduce(@statuses, socket, fn s, acc ->
      stream(acc, stream_name(s), Map.get(grouped, s, []), reset: true)
    end)
    |> assign(
      ticket_count: count,
      tickets_by_status: grouped,
      loop_info: Dags.active_loop_info_for_tickets(ticket_ids)
    )
  end
end
