defmodule AlgedoniaWeb.TicketLive.Index do
  @moduledoc """
  LiveView for ticket listing — board and list views with CRUD modals.
  """
  use AlgedoniaWeb, :live_view

  alias Algedonia.{Agents, Dags, Tickets}
  alias Algedonia.Loops
  alias Algedonia.Tickets.{Comment, Ticket}
  alias Algedonia.Workspaces

  import AlgedoniaWeb.TicketComponents
  import AlgedoniaWeb.CommentComponents
  import AlgedoniaWeb.PresenceComponents

  @statuses [:backlog, :planning, :halted, :in_progress, :completed, :archived]

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: Tickets.subscribe()
    workspace_slug = params["workspace"] || session["current_workspace_slug"]

    current_workspace =
      socket.assigns[:current_workspace] ||
        if session["current_workspace_id"] do
          Workspaces.get_workspace!(session["current_workspace_id"])
        else
          nil
        end

    {:ok,
     socket
     |> assign(:statuses, @statuses)
     |> assign(:confirm_delete, false)
     |> assign(:delete_ticket_id, nil)
     |> assign(:save_state, :idle)
     |> assign(:show_shortcut_help, false)
     |> assign(:current_user_id, session["user_id"])
     |> assign(:current_workspace_id, session["current_workspace_id"])
     |> assign(:current_workspace, current_workspace)
     |> assign(:workspace_prefix, session["current_workspace_prefix"] || "AG")
     |> assign(:workspace_slug, workspace_slug)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filter_state = filter_state_from_params(params)
    filters_changed? = filters_changed?(socket.assigns, filter_state)
    socket = assign(socket, filter_state)

    prior_action = socket.assigns[:last_live_action]

    socket =
      if filters_changed? || prior_action == :show do
        stream_tickets(socket)
      else
        socket
      end

    socket =
      socket
      |> assign(:last_live_action, socket.assigns.live_action)
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, socket}
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

  defp filters_changed?(assigns, filter_state) do
    !Map.has_key?(assigns, :filter_status) ||
      assigns.filter_status != filter_state.filter_status ||
      assigns.filter_assignee != filter_state.filter_assignee ||
      Map.get(assigns, :filter_query) != filter_state.filter_query ||
      assigns.view_mode != filter_state.view_mode ||
      Map.get(assigns, :sort_by) != filter_state.sort_by ||
      Map.get(assigns, :sort_order) != filter_state.sort_order
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Tickets", ticket: nil)
  end

  defp apply_action(socket, :new, params) do
    default_status = parse_status(params["status"]) || :backlog

    assign(socket,
      page_title: "New Ticket",
      ticket: %Ticket{status: default_status}
    )
  end

  defp apply_action(socket, :show, %{"ticket_ref" => ticket_ref}) do
    ticket = Tickets.get_ticket_by_ref!(socket.assigns.current_workspace.id, ticket_ref)

    if connected?(socket) do
      # Unsubscribe from previous ticket's comments if any
      old_ticket = socket.assigns[:ticket]

      if old_ticket && old_ticket.id != ticket.id do
        Phoenix.PubSub.unsubscribe(Algedonia.PubSub, "ticket:#{old_ticket.id}")
      end

      Tickets.subscribe_comments(ticket.id)
    end

    comments = Tickets.list_comments(ticket.id)
    comment_changeset = Tickets.change_comment(%Comment{ticket_id: ticket.id})
    ticket_changeset = Tickets.change_ticket(ticket)

    loop_id = first_loop_id(ticket)

    assign(socket,
      page_title: ticket.title,
      ticket: ticket,
      ticket_form: to_form(ticket_changeset),
      comments: comments,
      comment_form: to_form(comment_changeset),
      comment_form_id: "new_comment_0",
      confirm_delete: false,
      delete_ticket_id: nil,
      reply_to: nil,
      reply_form: nil,
      editing_comment_id: nil,
      edit_form: nil,
      loop_id: loop_id
    )
  end

  defp apply_action(socket, :edit, %{"ticket_ref" => ticket_ref}) do
    ticket = Tickets.get_ticket_by_ref!(socket.assigns.current_workspace.id, ticket_ref)
    assign(socket, page_title: "Edit Ticket", ticket: ticket)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    ticket = Tickets.get_ticket!(id)
    {:ok, _} = Tickets.delete_ticket(ticket)

    {:noreply,
     socket
     |> put_flash(:info, "Ticket deleted")
     |> push_patch(to: ~p"/w/#{socket.assigns.workspace_slug}/tickets")}
  end

  def handle_event("duplicate_ticket", %{"id" => id}, socket) do
    ticket = Tickets.get_ticket!(id)
    workspace = socket.assigns.current_workspace || Workspaces.get_workspace!(ticket.workspace_id)

    attrs = %{
      "title" => duplicate_title(ticket.title),
      "description" => ticket.description,
      "status" => :backlog,
      "type" => ticket.type,
      "coding_agent" => ticket.coding_agent,
      "priority" => ticket.priority,
      "assignee" => ticket.assignee,
      "acceptance_criteria" => ticket.acceptance_criteria,
      "rubric" => ticket.rubric,
      "max_attempts" => ticket.max_attempts
    }

    case Tickets.create_ticket_for_workspace(workspace, attrs) do
      {:ok, _copy} ->
        {:noreply, put_flash(socket, :info, "Issue duplicated")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Unable to duplicate issue")}
    end
  end

  def handle_event("confirm_delete", params, socket) do
    ticket_id =
      params["id"] || socket.assigns[:delete_ticket_id] ||
        (socket.assigns[:ticket] && socket.assigns[:ticket].id)

    {:noreply, assign(socket, confirm_delete: true, delete_ticket_id: ticket_id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: false, delete_ticket_id: nil)}
  end

  def handle_event("confirm_delete_now", params, socket) do
    id = params["id"] || socket.assigns.delete_ticket_id
    ticket = Tickets.get_ticket!(id)
    {:ok, _} = Tickets.delete_ticket(ticket)

    {:noreply,
     socket
     |> assign(:confirm_delete, false)
     |> assign(:delete_ticket_id, nil)
     |> put_flash(:info, "Issue deleted")
     |> push_patch(to: ~p"/w/#{socket.assigns.workspace_slug}/tickets")}
  end

  def handle_event("move_ticket", %{"id" => id, "status" => status}, socket) do
    ticket = Tickets.get_ticket!(id)

    status = parse_status(status) || ticket.status

    case Tickets.update_ticket(ticket, %{status: status}) do
      {:ok, _ticket} -> {:noreply, socket}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_view", %{"view" => view}, socket) do
    params = build_query_params(socket.assigns, view: view)
    {:noreply, push_patch(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets?#{params}")}
  end

  def handle_event("toggle_view_shortcut", _params, socket) do
    view = if socket.assigns.view_mode == :list, do: "board", else: "list"
    params = build_query_params(socket.assigns, view: view)
    {:noreply, push_patch(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets?#{params}")}
  end

  def handle_event("toggle_shortcut_help", _params, socket) do
    {:noreply, assign(socket, :show_shortcut_help, !socket.assigns.show_shortcut_help)}
  end

  def handle_event("shortcut_back", _params, socket) do
    if socket.assigns.live_action == :show do
      {:noreply, push_patch(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter", %{"status" => status}, socket) do
    params = build_query_params(socket.assigns, status: status)
    {:noreply, push_patch(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets?#{params}")}
  end

  def handle_event("sort", %{"sort_by" => sort_by}, socket) do
    params = build_query_params(socket.assigns, sort_by: sort_by)
    {:noreply, push_patch(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets?#{params}")}
  end

  def handle_event("clear_filters", _params, socket) do
    view = if socket.assigns.view_mode == :list, do: "list", else: "board"

    {:noreply,
     push_patch(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets?#{%{view: view}}")}
  end

  def handle_event("search", %{"q" => query}, socket) do
    params = build_query_params(socket.assigns, q: query)
    {:noreply, push_patch(socket, to: ~p"/w/#{socket.assigns.workspace_slug}/tickets?#{params}")}
  end

  def handle_event("start_work", %{"id" => ticket_id}, socket) do
    ticket = Tickets.get_ticket!(ticket_id)

    case ensure_single_loop(ticket) do
      {:ok, loop_id} ->
        path =
          ~p"/w/#{socket.assigns.workspace_slug}/tickets/#{ticket_ref(ticket)}/loops/#{loop_ref(loop_id)}?#{%{autostart: 1, agent_type: ticket_agent_type(ticket)}}"

        {:noreply, push_navigate(socket, to: path)}

      {:error, :invalid_status} ->
        {:noreply, put_flash(socket, :error, "Only backlog or halted tickets can start work")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to start work")}
    end
  end

  def handle_event("submit_comment", %{"comment" => params}, socket) do
    ticket = socket.assigns.ticket

    attrs =
      params
      |> Map.put("ticket_id", ticket.id)
      |> Map.put("author", socket.assigns.display_name)

    case Tickets.create_comment(attrs) do
      {:ok, _comment} ->
        changeset = Tickets.change_comment(%Comment{ticket_id: ticket.id})
        counter = next_form_counter(socket.assigns.comment_form_id)

        {:noreply,
         assign(socket,
           comment_form: to_form(changeset),
           comment_form_id: "new_comment_#{counter}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, comment_form: to_form(changeset))}
    end
  end

  def handle_event("autosave_ticket", %{"ticket" => params}, socket) do
    ticket = socket.assigns.ticket

    case Tickets.update_ticket(ticket, params) do
      {:ok, updated} ->
        changeset = Tickets.change_ticket(updated)

        {:noreply,
         socket
         |> assign(:ticket, updated)
         |> assign(:ticket_form, to_form(changeset))
         |> assign(:save_state, :saved)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:ticket_form, to_form(changeset))
         |> assign(:save_state, :error)}
    end
  end

  def handle_event("start_reply", %{"comment-id" => comment_id}, socket) do
    ticket = socket.assigns.ticket

    changeset =
      Tickets.change_comment(%Comment{ticket_id: ticket.id, parent_id: comment_id})

    {:noreply, assign(socket, reply_to: comment_id, reply_form: to_form(changeset))}
  end

  def handle_event("edit_comment", %{"id" => id}, socket) do
    comment = Tickets.get_comment!(id)
    changeset = Tickets.change_comment(comment)
    {:noreply, assign(socket, editing_comment_id: id, edit_form: to_form(changeset))}
  end

  def handle_event("update_comment", %{"comment" => params}, socket) do
    comment = Tickets.get_comment!(socket.assigns.editing_comment_id)

    case Tickets.update_comment(comment, params) do
      {:ok, _comment} ->
        {:noreply, assign(socket, editing_comment_id: nil, edit_form: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, edit_form: to_form(changeset))}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_comment_id: nil, edit_form: nil)}
  end

  def handle_event("delete_comment", %{"id" => id}, socket) do
    comment = Tickets.get_comment!(id)
    {:ok, _} = Tickets.delete_comment(comment)
    {:noreply, socket}
  end

  def handle_event("submit_reply", %{"comment" => params}, socket) do
    ticket = socket.assigns.ticket

    attrs =
      params
      |> Map.put("ticket_id", ticket.id)
      |> Map.put("author", socket.assigns.display_name)

    case Tickets.create_comment(attrs) do
      {:ok, _comment} ->
        {:noreply, assign(socket, reply_to: nil, reply_form: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, reply_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_info({event, _ticket}, socket)
      when event in [:ticket_created, :ticket_updated, :ticket_deleted] do
    {:noreply, stream_tickets(socket)}
  end

  def handle_info({event, _comment}, socket)
      when event in [:comment_created, :comment_updated, :comment_deleted] do
    ticket = socket.assigns[:ticket]

    if ticket do
      comments = Tickets.list_comments(ticket.id)
      {:noreply, assign(socket, comments: comments)}
    else
      {:noreply, socket}
    end
  end

  defp stream_tickets(socket) do
    %{
      filter_status: status,
      filter_assignee: assignee,
      filter_query: query,
      sort_by: sort_by,
      sort_order: sort_order
    } =
      socket.assigns

    opts = [
      status: status,
      assignee: assignee,
      sort_by: sort_by,
      sort_order: sort_order,
      workspace_id: socket.assigns.current_workspace_id
    ]

    grouped =
      opts
      |> Tickets.list_tickets_by_status()
      |> filter_grouped_by_query(query, socket.assigns.workspace_prefix)

    active_statuses = [:planning, :in_progress]

    all_count =
      grouped
      |> Map.take(active_statuses ++ [:backlog, :halted])
      |> Map.values()
      |> List.flatten()
      |> length()

    active_ticket_ids =
      grouped
      |> Map.take(active_statuses)
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)

    loop_ids = Dags.first_loop_ids_for_tickets(active_ticket_ids)

    socket =
      Enum.reduce(@statuses, socket, fn s, acc ->
        stream(acc, stream_name(s), Map.get(grouped, s, []), reset: true)
      end)

    assign(socket, ticket_count: all_count, tickets_by_status: grouped, loop_ids: loop_ids)
  end

  @doc false
  def stream_name(status), do: :"tickets_#{status}"

  defp parse_status(nil), do: nil
  defp parse_status(""), do: nil

  defp parse_status(status) when is_binary(status) do
    valid = Enum.map(@statuses, &to_string/1)
    if status in valid, do: String.to_existing_atom(status), else: nil
  end

  defp parse_status(status) when is_atom(status), do: status

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

    base = %{}
    base = if view != "board", do: Map.put(base, :view, view), else: base

    base =
      if status && status != "" do
        Map.put(base, :status, status)
      else
        base
      end

    base =
      if sort_by && to_string(sort_by) != "priority",
        do: Map.put(base, :sort_by, sort_by),
        else: base

    base =
      if query do
        Map.put(base, :q, query)
      else
        base
      end

    base
  end

  defp view_string(:list), do: "list"
  defp view_string(_), do: "board"

  defp normalize_filter_query(nil), do: nil

  defp normalize_filter_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp filter_grouped_by_query(grouped, nil, _prefix), do: grouped

  defp filter_grouped_by_query(grouped, query, prefix) do
    terms =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    Enum.into(grouped, %{}, fn {status, tickets} ->
      filtered = Enum.filter(tickets, &ticket_matches_query?(&1, terms, prefix))
      {status, filtered}
    end)
  end

  defp ticket_matches_query?(ticket, terms, prefix) do
    haystack =
      [
        ticket.title,
        ticket.description,
        ticket.assignee,
        ticket_search_code(ticket, prefix),
        String.slice(ticket.id, 0, 8)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.all?(terms, &String.contains?(haystack, &1))
  end

  defp ticket_agent_type(ticket), do: Agents.ticket_agent_type(ticket)

  defp ticket_search_code(%{number: number}, prefix) when is_integer(number),
    do: "#{prefix}-#{number}"

  defp ticket_search_code(%{id: id}, _prefix), do: String.slice(id, 0, 8)

  defp duplicate_title(title) when is_binary(title), do: "#{title} (Copy)"
  defp duplicate_title(_title), do: "Copied issue"

  defp ensure_single_loop(%Ticket{status: status}) when status not in [:backlog, :halted] do
    {:error, :invalid_status}
  end

  defp ensure_single_loop(%Ticket{} = ticket) do
    case Dags.get_dag_by_ticket(ticket.id) do
      nil ->
        create_single_loop(ticket)

      dag ->
        loop = dag.loops |> List.first()

        if loop do
          maybe_mark_in_progress(ticket)
          {:ok, loop.id}
        else
          create_loop_for_dag(dag, ticket)
        end
    end
  end

  defp create_single_loop(ticket) do
    case Dags.create_dag_with_loops(
           %{ticket_id: ticket.id},
           %{
             "loops" => [
               %{
                 "temp_id" => "primary",
                 "title" => ticket.title,
                 "description" => ticket.description || "",
                 "role" => "task",
                 "max_attempts" => ticket.max_attempts,
                 "rubric" => ticket.rubric || ""
               }
             ],
             "dependencies" => []
           }
         ) do
      {:ok, dag} ->
        maybe_mark_in_progress(ticket)
        {:ok, dag.loops |> List.first() |> Map.fetch!(:id)}

      {:error, _step, _changeset, _changes} ->
        {:error, :dag_create_failed}
    end
  end

  defp create_loop_for_dag(dag, ticket) do
    case Loops.create_loop(%{
           dag_id: dag.id,
           title: ticket.title,
           description: ticket.description || "",
           role: :task,
           max_attempts: ticket.max_attempts,
           rubric: ticket.rubric || ""
         }) do
      {:ok, loop} ->
        maybe_mark_in_progress(ticket)
        {:ok, loop.id}

      {:error, _changeset} ->
        {:error, :loop_create_failed}
    end
  end

  defp maybe_mark_in_progress(%Ticket{status: :in_progress}), do: :ok

  defp maybe_mark_in_progress(%Ticket{} = ticket) do
    _ = Tickets.update_ticket(ticket, %{status: :in_progress})
    :ok
  end

  defp first_loop_id(%Ticket{} = ticket) do
    case Dags.get_dag_by_ticket(ticket.id) do
      %{loops: [loop | _]} -> loop.id
      _ -> nil
    end
  end

  defp ticket_ref(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  defp ticket_ref(%{id: id}), do: id

  defp loop_ref(loop_id) when is_binary(loop_id), do: String.slice(loop_id, 0, 8)
  defp loop_ref(_), do: nil

  defp next_form_counter(current_id) do
    current_id
    |> String.split("_")
    |> List.last()
    |> String.to_integer()
    |> Kernel.+(1)
  end

  @doc false
  def stream_for(streams, status) do
    Map.get(streams, stream_name(status), [])
  end
end
