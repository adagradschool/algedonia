defmodule AlgedoniaWeb.TicketLive.Index do
  @moduledoc """
  LiveView for ticket listing — board and list views with CRUD modals.
  """
  use AlgedoniaWeb, :live_view

  alias Algedonia.{Dags, Tickets}
  alias Algedonia.Loops
  alias Algedonia.Tickets.{Comment, Ticket}
  alias Algedonia.Workspaces

  import AlgedoniaWeb.TicketComponents
  import AlgedoniaWeb.CommentComponents
  import AlgedoniaWeb.PresenceComponents

  @statuses [:backlog, :decomposing, :halted, :in_progress, :completed, :archived]

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
     |> assign(:current_user_id, session["user_id"])
     |> assign(:current_workspace_id, session["current_workspace_id"])
     |> assign(:current_workspace, current_workspace)
     |> assign(:workspace_prefix, session["current_workspace_prefix"] || "AG")
     |> assign(:workspace_slug, workspace_slug)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    view_mode = if params["view"] == "list", do: :list, else: :board
    filter_status = parse_status(params["status"])
    filter_assignee = params["assignee"]
    sort_by = parse_sort_by(params["sort_by"])
    sort_order = parse_sort_order(params["sort_order"])

    filters_changed? =
      !Map.has_key?(socket.assigns, :filter_status) ||
        socket.assigns.filter_status != filter_status ||
        socket.assigns.filter_assignee != filter_assignee ||
        socket.assigns.view_mode != view_mode ||
        Map.get(socket.assigns, :sort_by) != sort_by ||
        Map.get(socket.assigns, :sort_order) != sort_order

    socket =
      socket
      |> assign(
        view_mode: view_mode,
        filter_status: filter_status,
        filter_assignee: filter_assignee,
        sort_by: sort_by,
        sort_order: sort_order
      )

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

  defp apply_action(socket, :show, %{"id" => id}) do
    ticket = Tickets.get_ticket!(id)

    if connected?(socket) do
      # Unsubscribe from previous ticket's comments if any
      old_ticket = socket.assigns[:ticket]

      if old_ticket && old_ticket.id != id do
        Phoenix.PubSub.unsubscribe(Algedonia.PubSub, "ticket:#{old_ticket.id}")
      end

      Tickets.subscribe_comments(id)
    end

    comments = Tickets.list_comments(id)
    comment_changeset = Tickets.change_comment(%Comment{ticket_id: id})
    ticket_changeset = Tickets.change_ticket(ticket)

    assign(socket,
      page_title: ticket.title,
      ticket: ticket,
      ticket_form: to_form(ticket_changeset),
      comments: comments,
      comment_form: to_form(comment_changeset),
      comment_form_id: "new_comment_0",
      confirm_delete: false,
      reply_to: nil,
      reply_form: nil,
      editing_comment_id: nil,
      edit_form: nil
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    ticket = Tickets.get_ticket!(id)
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

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, false)}
  end

  def handle_event("confirm_delete_now", %{"id" => id}, socket) do
    ticket = Tickets.get_ticket!(id)
    {:ok, _} = Tickets.delete_ticket(ticket)

    {:noreply,
     socket
     |> assign(:confirm_delete, false)
     |> put_flash(:info, "Ticket deleted")
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

  def handle_event("start_work", %{"id" => ticket_id}, socket) do
    ticket = Tickets.get_ticket!(ticket_id)

    case ensure_single_loop(ticket) do
      {:ok, loop_id} ->
        path = ~p"/w/#{socket.assigns.workspace_slug}/loops/#{loop_id}?#{%{autostart: 1}}"
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
         |> assign(:ticket_form, to_form(changeset))}

      {:error, changeset} ->
        {:noreply, assign(socket, :ticket_form, to_form(changeset))}
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
    %{filter_status: status, filter_assignee: assignee, sort_by: sort_by, sort_order: sort_order} =
      socket.assigns

    opts = [
      status: status,
      assignee: assignee,
      sort_by: sort_by,
      sort_order: sort_order,
      workspace_id: socket.assigns.current_workspace_id
    ]

    grouped = Tickets.list_tickets_by_status(opts)
    all_count = grouped |> Map.values() |> List.flatten() |> length()

    socket =
      Enum.reduce(@statuses, socket, fn s, acc ->
        stream(acc, stream_name(s), Map.get(grouped, s, []), reset: true)
      end)

    assign(socket, ticket_count: all_count, tickets_by_status: grouped)
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

    base
  end

  defp view_string(:list), do: "list"
  defp view_string(_), do: "board"

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
                 "max_attempts" => 3,
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
           max_attempts: 3,
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
