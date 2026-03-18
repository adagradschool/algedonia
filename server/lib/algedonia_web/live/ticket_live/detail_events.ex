defmodule AlgedoniaWeb.TicketLive.DetailEvents do
  @moduledoc """
  Event handlers for the ticket detail panel — autosave, comments, planning
  workflow, and CRUD actions. Dispatched from `TicketLive.Index`.
  """
  use Phoenix.VerifiedRoutes, endpoint: AlgedoniaWeb.Endpoint, router: AlgedoniaWeb.Router

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 1]
  import AlgedoniaWeb.Helpers, only: [ticket_ref: 1, short_id: 1]

  alias Algedonia.{Agents, Loops, Tickets, Workspaces}
  alias Algedonia.Tickets.Comment

  @ticket_detail_fields [:description, :acceptance_criteria, :rubric]

  @doc """
  Loads ticket detail assigns onto the socket for the :show action.
  """
  @spec load_detail(Phoenix.LiveView.Socket.t(), Algedonia.Types.id(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def load_detail(socket, workspace_id, ticket_ref) do
    ticket = Tickets.get_ticket_by_ref!(workspace_id, ticket_ref)
    if connected?(socket), do: Loops.subscribe_ticket_loops(workspace_id, ticket.id)

    blocked_by_options = build_blocked_by_options(workspace_id, ticket.id)
    workspace = Workspaces.get_workspace!(workspace_id)
    assignee_options = Tickets.list_assignee_options(workspace_id)
    assignee_search = Tickets.assignee_display_name(assignee_options, ticket.assignee) || ""

    assign(socket,
      page_title: ticket.title,
      ticket: ticket,
      ticket_form: to_form(Tickets.change_ticket(ticket)),
      effective_land_mode: format_land_mode(Tickets.resolve_land_mode(ticket, workspace)),
      assignee_options: assignee_options,
      assignee_open: false,
      assignee_search: assignee_search,
      blocker_tickets: resolve_blocker_tickets(ticket),
      blocked_by_options: blocked_by_options,
      blocked_by_search: "",
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
      manual_run: empty_manual_run(),
      loop_id: Loops.first_inspect_loop_id(ticket.id),
      review_loop_id: Loops.first_review_loop_id(ticket.id),
      hook_loops: Loops.list_hook_loops_for_ticket(ticket.id),
      transition_hooks: Workspaces.list_transition_hooks(workspace_id)
    )
  end

  @spec empty_manual_run() :: map()
  def empty_manual_run do
    %{
      run_id: nil,
      status: :idle,
      output: "",
      exit_code: nil,
      started_at: nil,
      completed_at: nil,
      message: nil
    }
  end

  @doc false
  @spec handle(binary(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle("autosave_ticket", %{"ticket" => params}, socket) do
    autosave_ticket(socket, params)
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
        case Tickets.start_planning_work(planned) do
          {:ok, loop_id} ->
            {:noreply, push_navigate(socket, to: planning_path(socket, planned, loop_id))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Unable to start planning session")}
        end

      {:error, :invalid_status} ->
        {:noreply, put_flash(socket, :error, "Only backlog tickets can start planning")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unable to start planning")}
    end
  end

  def handle("open_planning_session", %{"id" => ticket_id}, socket) do
    ticket = Tickets.get_ticket!(ticket_id)

    if ticket.status == :planning do
      case Tickets.start_planning_work(ticket) do
        {:ok, loop_id} ->
          {:noreply, push_navigate(socket, to: planning_path(socket, ticket, loop_id))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Unable to start planning session")}
      end
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

  def handle("run_workspace_script", %{"id" => ticket_id}, socket) do
    alias AlgedoniaWeb.Helpers

    ticket = Tickets.get_ticket!(ticket_id)
    workspace = socket.assigns.current_workspace || Workspaces.get_workspace!(ticket.workspace_id)
    script = workspace.worktree_run_script

    cond do
      ticket.status not in [:in_progress, :in_review] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Workspace script is only available for in-progress or in-review tickets"
         )}

      socket.assigns.manual_run.status == :running ->
        {:noreply, put_flash(socket, :error, "Workspace script is already running")}

      is_nil(script) or String.trim(script) == "" ->
        {:noreply,
         put_flash(socket, :error, "Set a workspace run script in Settings before running it")}

      true ->
        case Helpers.resolve_daemon(socket) do
          {:ok, daemon} ->
            run_id = Ecto.UUID.generate()

            AlgedoniaWeb.DaemonChannel.push_run_workspace_script(daemon.name, %{
              "run_id" => run_id,
              "workspace_slug" => workspace.slug,
              "ticket_id" => ticket.id,
              "worktree_run_script" => script
            })

            {:noreply,
             assign(socket, :manual_run, %{
               run_id: run_id,
               status: :running,
               output: "",
               exit_code: nil,
               started_at: DateTime.utc_now(),
               completed_at: nil,
               message: nil
             })}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No online daemon available")}
        end
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
      "assignee" => duplicate_assignee(workspace.id, ticket.assignee),
      "acceptance_criteria" => ticket.acceptance_criteria,
      "rubric" => ticket.rubric
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

  def handle("pull_comments", %{"id" => ticket_id}, socket) do
    ticket = Tickets.get_ticket!(ticket_id)

    if ticket.status == :in_review do
      Algedonia.ReviewLoop.pull_comments(ticket)
      {:noreply, put_flash(socket, :info, "Fetching latest review comments...")}
    else
      {:noreply,
       put_flash(socket, :error, "Pull Comments is only available in the In Review phase")}
    end
  end

  def handle("filter_blocked_by_detail", %{"value" => query}, socket) do
    {:noreply, assign(socket, blocked_by_search: query)}
  end

  def handle("filter_assignee_detail", %{"value" => query}, socket) do
    {:noreply, assign(socket, assignee_search: query, assignee_open: true)}
  end

  def handle("open_assignee_detail", _params, socket) do
    {:noreply, assign(socket, :assignee_open, true)}
  end

  def handle("close_assignee_detail", _params, socket) do
    {:noreply, assign(socket, :assignee_open, false)}
  end

  def handle("select_detail_assignee", %{"assignee" => assignee} = params, socket) do
    socket =
      assign(socket,
        assignee_search: selected_assignee_label(params),
        assignee_open: false
      )

    params = Map.put(current_ticket_form_params(socket), "assignee", assignee)
    autosave_ticket(socket, params)
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
           review_loop_id: nil,
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

  defp autosave_ticket(socket, params) do
    case Tickets.update_ticket(socket.assigns.ticket, params) do
      {:ok, updated} -> {:noreply, assign_saved_ticket(socket, updated)}
      {:error, cs} -> {:noreply, assign_save_error(socket, cs)}
    end
  end

  defp assign_saved_ticket(socket, ticket) do
    workspace = Workspaces.get_workspace!(ticket.workspace_id)

    assign(socket,
      ticket: ticket,
      ticket_form: to_form(Tickets.change_ticket(ticket)),
      effective_land_mode: format_land_mode(Tickets.resolve_land_mode(ticket, workspace)),
      assignee_open: false,
      assignee_search:
        Tickets.assignee_display_name(socket.assigns.assignee_options, ticket.assignee) || "",
      blocker_tickets: resolve_blocker_tickets(ticket),
      loop_id: Loops.first_inspect_loop_id(ticket.id),
      review_loop_id: Loops.first_review_loop_id(ticket.id),
      save_state: :saved
    )
  end

  defp assign_save_error(socket, changeset) do
    assign(socket, ticket_form: to_form(changeset), save_state: :error)
  end

  defp current_ticket_form_params(socket) do
    socket.assigns.ticket_form.source.params || %{}
  end

  defp work_loop_path(socket, ticket, loop_id) do
    slug = socket.assigns.workspace_slug

    ~p"/w/#{slug}/tickets/#{ticket_ref(ticket)}/loops/#{short_id(loop_id)}?#{%{agent_type: Agents.ticket_agent_type(ticket)}}"
  end

  defp planning_path(socket, ticket, loop_id) do
    slug = socket.assigns.workspace_slug

    ~p"/w/#{slug}/tickets/#{ticket_ref(ticket)}/loops/#{short_id(loop_id)}?#{%{role: "planning", agent_type: Agents.ticket_agent_type(ticket)}}"
  end

  defp next_form_counter(id),
    do: id |> String.split("_") |> List.last() |> String.to_integer() |> Kernel.+(1)

  defp duplicate_title(title) when is_binary(title), do: "#{title} (Copy)"
  defp duplicate_title(_), do: "Copied issue"

  defp duplicate_assignee(workspace_id, assignee) when is_binary(assignee) do
    workspace_id
    |> Tickets.list_assignee_options()
    |> Tickets.assignee_value(assignee)
  end

  defp duplicate_assignee(_workspace_id, _assignee), do: nil

  defp selected_assignee_label(params) do
    params
    |> Map.get("label", "")
    |> to_string()
  end

  defp parse_detail_field(field) when is_binary(field) do
    case Enum.find(@ticket_detail_fields, &(Atom.to_string(&1) == field)) do
      nil -> :error
      f -> {:ok, f}
    end
  end

  defp parse_detail_field(_), do: :error

  defp build_blocked_by_options(workspace_id, ticket_id) do
    Tickets.list_tickets(workspace_id: workspace_id)
    |> Enum.reject(&(&1.id == ticket_id))
    |> Enum.map(&{"##{&1.number} #{&1.title}", &1.id})
  end

  defp format_land_mode(:auto_land), do: "Auto Land"
  defp format_land_mode(:review_gate), do: "Review Gate"
  defp format_land_mode(_), do: "Review Gate"

  defp resolve_blocker_tickets(%{blocked_by: ids}) when is_list(ids) and ids != [] do
    Tickets.get_tickets_by_ids(ids)
  end

  defp resolve_blocker_tickets(_), do: []
end
