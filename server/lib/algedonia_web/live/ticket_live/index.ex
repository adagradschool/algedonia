defmodule AlgedoniaWeb.TicketLive.Index do
  @moduledoc """
  LiveView for ticket listing — board and list views with detail panel.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  alias Algedonia.{Loops, Tickets}
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
    open_editor export_markdown duplicate_ticket confirm_delete cancel_delete confirm_delete_now
    confirm_reset cancel_reset confirm_reset_now pull_comments)

  @impl true
  def mount(params, session, socket) do
    workspace_slug = params["workspace"] || session["current_workspace_slug"]

    current_workspace =
      socket.assigns[:current_workspace] ||
        (session["current_workspace_id"] &&
           Workspaces.get_workspace!(session["current_workspace_id"]))

    current_workspace_id = current_workspace && current_workspace.id
    workspace_prefix = if current_workspace, do: current_workspace.prefix, else: "AG"

    if connected?(socket) && current_workspace_id do
      Tickets.subscribe(current_workspace_id)
    end

    {:ok,
     assign(socket,
       statuses: @statuses,
       show_shortcut_help: false,
       current_user_id: session["user_id"],
       current_workspace_id: current_workspace_id,
       current_workspace: current_workspace,
       workspace_prefix: workspace_prefix,
       workspace_slug: workspace_slug,
       save_state: :idle,
       confirm_delete: false,
       delete_ticket_id: nil,
       confirm_reset: false
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filter_state = filter_state_from_params(params)
    filters_changed? = filters_changed?(socket.assigns, filter_state)

    socket =
      socket
      |> assign(filter_state)
      |> assign(
        url_has_sort?: Map.has_key?(params, "sort_by"),
        url_has_view?: Map.has_key?(params, "view")
      )

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
    {:noreply,
     socket
     |> push_prefs(view_mode: view, sort_by: socket.assigns.sort_by)
     |> push_patch(to: tickets_path(socket, view: view))}
  end

  def handle_event("toggle_view_shortcut", _p, socket) do
    view = if socket.assigns.view_mode == :list, do: "board", else: "list"

    {:noreply,
     socket
     |> push_prefs(view_mode: view, sort_by: socket.assigns.sort_by)
     |> push_patch(to: tickets_path(socket, view: view))}
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
    view = if socket.assigns.view_mode == :list, do: "list", else: "board"

    {:noreply,
     socket
     |> push_prefs(view_mode: view, sort_by: sort_by)
     |> push_patch(to: tickets_path(socket, sort_by: sort_by))}
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

  def handle_event("restore_prefs", prefs, socket) do
    overrides =
      []
      |> then(fn acc ->
        if !socket.assigns.url_has_sort? && is_binary(prefs["sort_by"]),
          do: [{:sort_by, prefs["sort_by"]} | acc],
          else: acc
      end)
      |> then(fn acc ->
        if !socket.assigns.url_has_view? && is_binary(prefs["view_mode"]),
          do: [{:view, prefs["view_mode"]} | acc],
          else: acc
      end)

    if overrides == [] do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: tickets_path(socket, overrides))}
    end
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
  def handle_info({:ticket_created, ticket}, socket) do
    {:noreply, stream_insert_ticket(socket, ticket)}
  end

  def handle_info({:ticket_updated, ticket}, socket) do
    {:noreply, stream_update_ticket(socket, ticket)}
  end

  def handle_info({:ticket_deleted, ticket}, socket) do
    {:noreply, stream_delete_ticket(socket, ticket)}
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
      loop_info: Loops.active_loop_info_for_tickets(ticket_ids)
    )
  end

  defp stream_insert_ticket(socket, ticket) do
    loop_info = Loops.active_loop_info_for_tickets([ticket.id])

    socket
    |> stream_insert(stream_name(ticket.status), ticket)
    |> update(:loop_info, &Map.merge(&1, loop_info))
    |> update_ticket_count(ticket.status, +1)
  end

  defp stream_update_ticket(socket, ticket) do
    old_status = find_old_status(socket.assigns.tickets_by_status, ticket.id)
    loop_info = Loops.active_loop_info_for_tickets([ticket.id])

    socket =
      if old_status && old_status != ticket.status do
        socket
        |> stream_delete(stream_name(old_status), ticket)
        |> update_ticket_count(old_status, -1)
        |> stream_insert(stream_name(ticket.status), ticket)
        |> update_ticket_count(ticket.status, +1)
      else
        stream_insert(socket, stream_name(ticket.status), ticket)
      end

    socket
    |> update(:loop_info, &Map.merge(&1, loop_info))
    |> update_tickets_by_status(old_status, ticket)
  end

  defp stream_delete_ticket(socket, ticket) do
    socket
    |> stream_delete(stream_name(ticket.status), ticket)
    |> update(:loop_info, &Map.delete(&1, ticket.id))
    |> update_ticket_count(ticket.status, -1)
    |> update(:tickets_by_status, fn grouped ->
      Map.update(grouped, ticket.status, [], fn tickets ->
        Enum.reject(tickets, &(&1.id == ticket.id))
      end)
    end)
  end

  defp find_old_status(tickets_by_status, ticket_id) do
    Enum.find_value(tickets_by_status, fn {status, tickets} ->
      if Enum.any?(tickets, &(&1.id == ticket_id)), do: status
    end)
  end

  defp update_ticket_count(socket, status, delta) do
    countable = [:planning, :in_progress, :in_review, :backlog, :halted]

    if status in countable do
      update(socket, :ticket_count, &max(&1 + delta, 0))
    else
      socket
    end
  end

  defp update_tickets_by_status(socket, old_status, ticket) do
    update(socket, :tickets_by_status, &do_update_grouped(&1, old_status, ticket))
  end

  defp do_update_grouped(grouped, old_status, ticket) do
    grouped
    |> maybe_remove_from_old(old_status, ticket)
    |> upsert_in_status(ticket)
  end

  defp maybe_remove_from_old(grouped, old_status, ticket)
       when is_atom(old_status) and old_status != nil and old_status != ticket.status do
    Map.update(grouped, old_status, [], &Enum.reject(&1, fn t -> t.id == ticket.id end))
  end

  defp maybe_remove_from_old(grouped, _old_status, _ticket), do: grouped

  defp upsert_in_status(grouped, ticket) do
    Map.update(grouped, ticket.status, [ticket], fn tickets ->
      case Enum.find_index(tickets, &(&1.id == ticket.id)) do
        nil -> [ticket | tickets]
        idx -> List.replace_at(tickets, idx, ticket)
      end
    end)
  end

  defp push_prefs(socket, opts) do
    push_event(socket, "persist_prefs", %{
      sort_by: to_string(opts[:sort_by]),
      view_mode: to_string(opts[:view_mode])
    })
  end
end
