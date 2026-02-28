defmodule AlgedoniaWeb.TicketLive.Index do
  @moduledoc """
  LiveView for ticket listing — board and list views with detail panel.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  alias Algedonia.{Dags, Tickets}
  alias Algedonia.Tickets.{Comment, Ticket}
  alias Algedonia.Workspaces
  alias AlgedoniaWeb.TicketLive.DetailEvents

  import AlgedoniaWeb.TicketComponents
  import AlgedoniaWeb.PresenceComponents

  @statuses Tickets.display_statuses()

  @detail_events ~w(autosave_ticket autosave_ticket_markdown
    submit_comment submit_reply start_reply edit_comment update_comment
    cancel_edit delete_comment start_work plan_ticket open_planning_session
    duplicate_ticket confirm_delete cancel_delete confirm_delete_now)

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: Tickets.subscribe()
    workspace_slug = params["workspace"] || session["current_workspace_slug"]

    current_workspace =
      socket.assigns[:current_workspace] ||
        if(session["current_workspace_id"],
          do: Workspaces.get_workspace!(session["current_workspace_id"])
        )

    {:ok,
     socket
     |> assign(:statuses, @statuses)
     |> assign(:show_shortcut_help, false)
     |> assign(:current_user_id, session["user_id"])
     |> assign(:current_workspace_id, session["current_workspace_id"])
     |> assign(:current_workspace, current_workspace)
     |> assign(:workspace_prefix, session["current_workspace_prefix"] || "AG")
     |> assign(:workspace_slug, workspace_slug)
     |> assign(:save_state, :idle)
     |> assign(:confirm_delete, false)
     |> assign(:delete_ticket_id, nil)}
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

  defp apply_action(socket, :show, %{"ticket_ref" => ticket_ref}) do
    ticket = Tickets.get_ticket_by_ref!(socket.assigns.current_workspace.id, ticket_ref)

    assign(socket,
      page_title: ticket.title,
      ticket: ticket,
      ticket_form: to_form(Tickets.change_ticket(ticket)),
      comments: Tickets.list_comments(ticket.id),
      comment_form: to_form(Tickets.change_comment(%Comment{ticket_id: ticket.id})),
      comment_form_id: "new_comment_0",
      confirm_delete: false,
      delete_ticket_id: nil,
      reply_to: nil,
      reply_form: nil,
      editing_comment_id: nil,
      edit_form: nil,
      loop_id: first_loop_id(ticket)
    )
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

  # -- Streams --

  defp stream_tickets(socket) do
    %{grouped: grouped, count: count} =
      Tickets.search_tickets_grouped(
        status: socket.assigns.filter_status,
        assignee: socket.assigns.filter_assignee,
        sort_by: socket.assigns.sort_by,
        sort_order: socket.assigns.sort_order,
        workspace_id: socket.assigns.current_workspace_id,
        query: socket.assigns.filter_query,
        prefix: socket.assigns.workspace_prefix
      )

    active_ids =
      grouped
      |> Map.take([:planning, :in_progress])
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)

    Enum.reduce(@statuses, socket, fn s, acc ->
      stream(acc, stream_name(s), Map.get(grouped, s, []), reset: true)
    end)
    |> assign(
      ticket_count: count,
      tickets_by_status: grouped,
      loop_ids: Dags.first_loop_ids_for_tickets(active_ids)
    )
  end

  # -- Helpers --

  @doc false
  def stream_name(status), do: :"tickets_#{status}"

  @doc false
  def stream_for(streams, status), do: Map.get(streams, stream_name(status), [])

  defp first_loop_id(%Ticket{} = ticket) do
    case Dags.get_dag_by_ticket(ticket.id) do
      %{loops: [loop | _]} -> loop.id
      _ -> nil
    end
  end

  defp tickets_path(socket, overrides \\ []) do
    ~p"/w/#{socket.assigns.workspace_slug}/tickets?#{build_query_params(socket.assigns, overrides)}"
  end

  defp filter_state_from_params(params) do
    %{
      view_mode: if(params["view"] == "list", do: :list, else: :board),
      filter_status: parse_status(params["status"]),
      filter_assignee: params["assignee"],
      filter_query: normalize_filter_query(params["q"]),
      sort_by: parse_sort_by(params["sort_by"]),
      sort_order: parse_sort_order(params["sort_order"])
    }
  end

  defp filters_changed?(assigns, fs) do
    !Map.has_key?(assigns, :filter_status) || assigns.filter_status != fs.filter_status ||
      assigns.filter_assignee != fs.filter_assignee ||
      Map.get(assigns, :filter_query) != fs.filter_query ||
      assigns.view_mode != fs.view_mode || Map.get(assigns, :sort_by) != fs.sort_by ||
      Map.get(assigns, :sort_order) != fs.sort_order
  end

  defp parse_status(nil), do: nil
  defp parse_status(""), do: nil

  defp parse_status(s) when is_binary(s),
    do: if(s in Enum.map(@statuses, &to_string/1), do: String.to_existing_atom(s))

  defp parse_status(s) when is_atom(s), do: s

  defp parse_sort_by(nil), do: :priority
  defp parse_sort_by("inserted_at"), do: :inserted_at
  defp parse_sort_by("title"), do: :title
  defp parse_sort_by(_), do: :priority

  defp parse_sort_order(nil), do: :asc
  defp parse_sort_order("desc"), do: :desc
  defp parse_sort_order(_), do: :asc

  defp build_query_params(assigns, overrides) do
    view = Keyword.get(overrides, :view) || view_string(assigns.view_mode)
    status = Keyword.get(overrides, :status, assigns.filter_status)
    sort_by = Keyword.get(overrides, :sort_by, assigns.sort_by)
    query = normalize_filter_query(Keyword.get(overrides, :q, assigns.filter_query))

    %{}
    |> then(&if(view != "board", do: Map.put(&1, :view, view), else: &1))
    |> then(&if(status in [nil, ""], do: &1, else: Map.put(&1, :status, status)))
    |> then(
      &if(sort_by && to_string(sort_by) != "priority",
        do: Map.put(&1, :sort_by, sort_by),
        else: &1
      )
    )
    |> then(&if(query, do: Map.put(&1, :q, query), else: &1))
  end

  defp view_string(:list), do: "list"
  defp view_string(_), do: "board"

  defp normalize_filter_query(nil), do: nil

  defp normalize_filter_query(q) when is_binary(q),
    do: if(String.trim(q) == "", do: nil, else: String.trim(q))
end
