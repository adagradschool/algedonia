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
    confirm_reset cancel_reset confirm_reset_now pull_comments filter_blocked_by_detail)

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
       sort_preferences: default_sort_preferences(),
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
      |> assign(url_has_view?: Map.has_key?(params, "view"))

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
     |> push_prefs(view_mode: view)
     |> push_patch(to: tickets_path(socket, view: view))}
  end

  def handle_event("toggle_view_shortcut", _p, socket) do
    view = if socket.assigns.view_mode == :list, do: "board", else: "list"

    {:noreply,
     socket
     |> push_prefs(view_mode: view)
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

  def handle_event("set_status_sort", %{"status" => status} = params, socket) do
    case parse_status(status) do
      nil ->
        {:noreply, socket}

      status ->
        sort_preferences =
          update_sort_preference(socket.assigns.sort_preferences, status, %{
            sort_by: params["sort_by"],
            sort_order: params["sort_order"]
          })

        {:noreply,
         socket
         |> assign(:sort_preferences, sort_preferences)
         |> stream_tickets()
         |> push_prefs()}
    end
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
    sort_preferences = restored_sort_preferences(prefs, socket.assigns.sort_preferences)
    socket = maybe_assign_sort_preferences(socket, sort_preferences)
    view_override = restored_view_mode(prefs, socket.assigns.url_has_view?)

    if view_override do
      {:noreply, push_patch(socket, to: tickets_path(socket, view: view_override))}
    else
      {:noreply, socket}
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
  def handle_info({:ticket_created, _ticket}, socket) do
    {:noreply, stream_tickets(socket)}
  end

  def handle_info({:ticket_updated, ticket}, socket) do
    socket =
      if socket.assigns[:ticket] && socket.assigns.ticket.id == ticket.id do
        blocker_tickets = Tickets.get_tickets_by_ids(ticket.blocked_by || [])

        assign(socket,
          ticket: ticket,
          ticket_form: to_form(Tickets.change_ticket(ticket)),
          blocker_tickets: blocker_tickets,
          blocked_by_options:
            Tickets.list_tickets(workspace_id: ticket.workspace_id)
            |> Enum.reject(&(&1.id == ticket.id))
            |> Enum.map(&{"##{&1.number} #{&1.title}", &1.id})
        )
      else
        socket
      end

    {:noreply, stream_tickets(socket)}
  end

  def handle_info({:ticket_deleted, _ticket}, socket) do
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
         assign(socket,
           loop_id: Algedonia.Loops.first_inspect_loop_id(ticket.id),
           review_loop_id: Algedonia.Loops.first_review_loop_id(ticket.id),
           hook_loops: Algedonia.Loops.list_hook_loops_for_ticket(ticket.id)
         )},
      else: {:noreply, socket}
  end

  # -- Streams --

  defp restored_sort_preferences(prefs, current_preferences) do
    case Map.get(prefs, "sort_preferences") || Map.get(prefs, :sort_preferences) do
      preferences when is_map(preferences) -> normalize_sort_preferences(preferences)
      _ -> current_preferences
    end
  end

  defp maybe_assign_sort_preferences(socket, sort_preferences) do
    if sort_preferences == socket.assigns.sort_preferences do
      socket
    else
      socket
      |> assign(:sort_preferences, sort_preferences)
      |> stream_tickets()
    end
  end

  defp restored_view_mode(_prefs, true), do: nil

  defp restored_view_mode(prefs, false) do
    case Map.get(prefs, "view_mode") || Map.get(prefs, :view_mode) do
      view when view in ["board", "list"] -> view
      _ -> nil
    end
  end

  defp stream_tickets(socket) do
    a = socket.assigns

    %{grouped: grouped, count: count} =
      Tickets.search_tickets_grouped(
        status: a.filter_status,
        assignee: a.filter_assignee,
        sort_preferences: a.sort_preferences,
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

  defp push_prefs(socket, opts \\ []) do
    push_event(socket, "persist_prefs", %{
      view_mode: to_string(Keyword.get(opts, :view_mode, socket.assigns.view_mode)),
      sort_preferences:
        encode_sort_preferences(
          Keyword.get(opts, :sort_preferences, socket.assigns.sort_preferences)
        )
    })
  end
end
