defmodule AlgedoniaWeb.TicketLive.DetailEvents do
  @moduledoc """
  Event handlers for the ticket detail panel — autosave, comments, planning
  workflow, and CRUD actions. Dispatched from `TicketLive.Index`.
  """
  use Phoenix.VerifiedRoutes, endpoint: AlgedoniaWeb.Endpoint, router: AlgedoniaWeb.Router

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, to_form: 1]
  import AlgedoniaWeb.Helpers, only: [ticket_ref: 1, short_id: 1]

  alias Algedonia.{Agents, Loops, Tickets, Workspaces}
  alias Algedonia.Tickets.Comment

  @ticket_detail_fields [:description, :acceptance_criteria, :rubric]

  @doc """
  Loads ticket detail assigns onto the socket for the :show action.
  """
  def load_detail(socket, workspace_id, ticket_ref) do
    ticket = Tickets.get_ticket_by_ref!(workspace_id, ticket_ref)
    if connected?(socket), do: Loops.subscribe_ticket_loops(ticket.id)

    assign(socket,
      page_title: ticket.title,
      ticket: ticket,
      ticket_form: to_form(Tickets.change_ticket(ticket)),
      comments: Tickets.list_comments(ticket.id),
      comment_form: to_form(Tickets.change_comment(%Comment{ticket_id: ticket.id})),
      comment_form_id: "new_comment_0",
      confirm_delete: false,
      delete_ticket_id: nil,
      confirm_reset: false,
      reply_to: nil,
      reply_form: nil,
      editing_comment_id: nil,
      edit_form: nil,
      loop_id: Loops.first_inspect_loop_id(ticket.id),
      hook_loops: Loops.list_hook_loops_for_ticket(ticket.id),
      transition_hooks: Workspaces.list_transition_hooks(workspace_id)
    )
  end

  @doc false
  def handle("autosave_ticket", %{"ticket" => params}, socket) do
    case Tickets.update_ticket(socket.assigns.ticket, params) do
      {:ok, updated} -> {:noreply, assign_saved_ticket(socket, updated)}
      {:error, cs} -> {:noreply, assign_save_error(socket, cs)}
    end
  end

  def handle("autosave_ticket_markdown", %{"field" => field, "body" => body}, socket) do
    with {:ok, f} <- parse_detail_field(field),
         {:ok, updated} <- Tickets.update_ticket(socket.assigns.ticket, %{f => body || ""}) do
      {:noreply, assign_saved_ticket(socket, updated)}
    else
      {:error, cs} when is_struct(cs, Ecto.Changeset) -> {:noreply, assign_save_error(socket, cs)}
      _ -> {:noreply, socket}
    end
  end

  def handle("submit_comment", %{"comment" => params}, socket) do
    ticket = socket.assigns.ticket

    attrs =
      Map.merge(params, %{"ticket_id" => ticket.id, "author" => socket.assigns.display_name})

    case Tickets.create_comment(attrs) do
      {:ok, _} ->
        counter = next_form_counter(socket.assigns.comment_form_id)
        cs = Tickets.change_comment(%Comment{ticket_id: ticket.id})

        {:noreply,
         assign(socket, comment_form: to_form(cs), comment_form_id: "new_comment_#{counter}")}

      {:error, cs} ->
        {:noreply, assign(socket, comment_form: to_form(cs))}
    end
  end

  def handle("submit_reply", %{"comment" => params}, socket) do
    attrs =
      Map.merge(params, %{
        "ticket_id" => socket.assigns.ticket.id,
        "author" => socket.assigns.display_name
      })

    case Tickets.create_comment(attrs) do
      {:ok, _} -> {:noreply, assign(socket, reply_to: nil, reply_form: nil)}
      {:error, cs} -> {:noreply, assign(socket, reply_form: to_form(cs))}
    end
  end

  def handle("start_reply", %{"comment-id" => cid}, socket) do
    cs = Tickets.change_comment(%Comment{ticket_id: socket.assigns.ticket.id, parent_id: cid})
    {:noreply, assign(socket, reply_to: cid, reply_form: to_form(cs))}
  end

  def handle("edit_comment", %{"id" => id}, socket) do
    comment = Tickets.get_comment!(id)

    {:noreply,
     assign(socket, editing_comment_id: id, edit_form: to_form(Tickets.change_comment(comment)))}
  end

  def handle("update_comment", %{"comment" => params}, socket) do
    comment = Tickets.get_comment!(socket.assigns.editing_comment_id)

    case Tickets.update_comment(comment, params) do
      {:ok, _} -> {:noreply, assign(socket, editing_comment_id: nil, edit_form: nil)}
      {:error, cs} -> {:noreply, assign(socket, edit_form: to_form(cs))}
    end
  end

  def handle("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_comment_id: nil, edit_form: nil)}
  end

  def handle("delete_comment", %{"id" => id}, socket) do
    {:ok, _} = Tickets.delete_comment(Tickets.get_comment!(id))
    {:noreply, socket}
  end

  def handle("start_work", %{"id" => ticket_id}, socket) do
    ticket = Tickets.get_ticket!(ticket_id)

    case Tickets.start_work(ticket) do
      {:ok, loop_id} ->
        {:noreply, push_navigate(socket, to: work_loop_path(socket, ticket, loop_id))}

      {:error, :invalid_status} ->
        {:noreply, put_flash(socket, :error, "Only planning or halted tickets can start work")}

      {:error, :no_online_daemon} ->
        {:noreply, put_flash(socket, :error, "No online daemon available")}

      {:error, :daemon_repo_not_ready} ->
        {:noreply, put_flash(socket, :error, "Daemon repository is not ready yet")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to start work")}
    end
  end

  def handle("plan_ticket", %{"id" => ticket_id}, socket) do
    ticket = Tickets.get_ticket!(ticket_id)

    case Tickets.start_planning(ticket) do
      {:ok, planned} ->
        {:noreply, push_navigate(socket, to: planning_path(socket, planned))}

      {:error, :invalid_status} ->
        {:noreply, put_flash(socket, :error, "Only backlog tickets can start planning")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to start planning")}
    end
  end

  def handle("open_planning_session", %{"id" => ticket_id}, socket) do
    ticket = Tickets.get_ticket!(ticket_id)

    if ticket.status == :planning do
      {:noreply, push_navigate(socket, to: planning_path(socket, ticket))}
    else
      {:noreply,
       put_flash(socket, :error, "Planning session is only available in planning stage")}
    end
  end

  def handle("open_editor", %{"id" => ticket_id}, socket) do
    alias AlgedoniaWeb.Helpers

    case Helpers.resolve_daemon(socket) do
      {:ok, daemon} ->
        AlgedoniaWeb.DaemonChannel.push_open_editor(
          daemon.name,
          ticket_id,
          socket.assigns.workspace_slug
        )

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No online daemon available")}
    end
  end

  def handle("export_markdown", %{"id" => id}, socket) do
    ticket = Tickets.get_ticket!(id)
    slug = socket.assigns.workspace_slug
    ref = ticket_ref(ticket)
    url = ~p"/w/#{slug}/tickets/#{ref}/export/markdown"
    {:noreply, redirect(socket, to: url)}
  end

  def handle("duplicate_ticket", %{"id" => id}, socket) do
    ticket = Tickets.get_ticket!(id)

    workspace =
      socket.assigns.current_workspace || Algedonia.Workspaces.get_workspace!(ticket.workspace_id)

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
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Issue duplicated")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Unable to duplicate issue")}
    end
  end

  def handle("confirm_delete", params, socket) do
    tid =
      params["id"] || socket.assigns[:delete_ticket_id] ||
        (socket.assigns[:ticket] && socket.assigns.ticket.id)

    {:noreply, assign(socket, confirm_delete: true, delete_ticket_id: tid)}
  end

  def handle("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: false, delete_ticket_id: nil)}
  end

  def handle("confirm_delete_now", params, socket) do
    id = params["id"] || socket.assigns.delete_ticket_id
    {:ok, _} = Tickets.delete_ticket(Tickets.get_ticket!(id))
    slug = socket.assigns.workspace_slug

    {:noreply,
     socket
     |> assign(confirm_delete: false, delete_ticket_id: nil)
     |> put_flash(:info, "Issue deleted")
     |> push_patch(to: ~p"/w/#{slug}/tickets")}
  end

  def handle("confirm_reset", _params, socket) do
    {:noreply, assign(socket, confirm_reset: true)}
  end

  def handle("cancel_reset", _params, socket) do
    {:noreply, assign(socket, confirm_reset: false)}
  end

  def handle("confirm_reset_now", _params, socket) do
    ticket = socket.assigns.ticket

    case Tickets.reset_ticket(ticket) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(
           confirm_reset: false,
           loop_id: nil,
           hook_loops: []
         )
         |> assign_saved_ticket(updated)
         |> put_flash(:info, "Issue reset to backlog")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(confirm_reset: false)
         |> put_flash(:error, "Unable to reset issue")}
    end
  end

  # -- Helpers --

  defp assign_saved_ticket(socket, ticket) do
    assign(socket,
      ticket: ticket,
      ticket_form: to_form(Tickets.change_ticket(ticket)),
      save_state: :saved
    )
  end

  defp assign_save_error(socket, changeset) do
    assign(socket, ticket_form: to_form(changeset), save_state: :error)
  end

  defp work_loop_path(socket, ticket, loop_id) do
    slug = socket.assigns.workspace_slug

    ~p"/w/#{slug}/tickets/#{ticket_ref(ticket)}/loops/#{short_id(loop_id)}?#{%{agent_type: Agents.ticket_agent_type(ticket)}}"
  end

  defp planning_path(socket, ticket) do
    slug = socket.assigns.workspace_slug
    ref = "plan-" <> short_id(ticket.id)

    ~p"/w/#{slug}/tickets/#{ticket_ref(ticket)}/loops/#{ref}?#{%{role: "planning", agent_type: Agents.ticket_agent_type(ticket)}}"
  end

  defp next_form_counter(id),
    do: id |> String.split("_") |> List.last() |> String.to_integer() |> Kernel.+(1)

  defp duplicate_title(title) when is_binary(title), do: "#{title} (Copy)"
  defp duplicate_title(_), do: "Copied issue"

  defp parse_detail_field(field) when is_binary(field) do
    case Enum.find(@ticket_detail_fields, &(Atom.to_string(&1) == field)) do
      nil -> :error
      f -> {:ok, f}
    end
  end

  defp parse_detail_field(_), do: :error
end
