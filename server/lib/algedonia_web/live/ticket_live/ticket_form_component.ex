defmodule AlgedoniaWeb.TicketLive.TicketFormComponent do
  @moduledoc """
  LiveComponent for create/edit ticket modal form.
  """
  use AlgedoniaWeb, :live_component

  alias Algedonia.Tickets

  @impl true
  def update(%{ticket: ticket, action: action} = assigns, socket) do
    changeset = Tickets.change_ticket(ticket)
    workspace = Map.get(assigns, :workspace)

    blocked_by_options =
      if workspace do
        Tickets.list_tickets(workspace_id: workspace.id)
        |> Enum.reject(&(&1.id == ticket.id))
        |> Enum.map(&{"##{&1.number} #{&1.title}", &1.id})
      else
        []
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:action_label, if(action == :new, do: "Save issue", else: "Update issue"))
     |> assign(:blocked_by_options, blocked_by_options)
     |> assign(:blocked_by_search, "")
     |> assign_new(:return_to, fn ->
       workspace_slug = Map.get(assigns, :workspace_slug)
       if workspace_slug, do: ~p"/w/#{workspace_slug}/tickets", else: "/tickets"
     end)
     |> assign_new(:workspace, fn -> nil end)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"ticket" => ticket_params}, socket) do
    changeset =
      socket.assigns.ticket
      |> Tickets.change_ticket(ticket_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("filter_blocked_by", %{"value" => query}, socket) do
    {:noreply, assign(socket, :blocked_by_search, query)}
  end

  def handle_event("save", %{"ticket" => ticket_params}, socket) do
    save_ticket(socket, socket.assigns.action, ticket_params)
  end

  defp save_ticket(socket, :new, ticket_params) do
    result =
      case socket.assigns.workspace do
        nil -> Tickets.create_ticket(ticket_params)
        workspace -> Tickets.create_ticket_for_workspace(workspace, ticket_params)
      end

    case result do
      {:ok, _ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ticket created")
         |> push_patch(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_ticket(socket, :edit, ticket_params) do
    case Tickets.update_ticket(socket.assigns.ticket, ticket_params) do
      {:ok, _ticket} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ticket updated")
         |> push_patch(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  def status_options do
    Algedonia.Tickets.display_statuses()
    |> Enum.map(&{status_label(&1), &1})
  end

  def priority_options do
    [
      "1 — Urgent": 1,
      "2 — High": 2,
      "3 — Medium": 3,
      "4 — Low": 4,
      "5 — Minimal": 5
    ]
  end

  def type_options do
    [Feature: :feature, Bug: :bug, Chore: :chore, Spike: :spike]
  end

  def coding_agent_options do
    [Codex: :codex, Claude: :claude_code]
  end

  def filtered_blocked_by_options(options, search) do
    if search == "" do
      options
    else
      q = String.downcase(search)
      Enum.filter(options, fn {label, _id} -> String.contains?(String.downcase(label), q) end)
    end
  end

  defp status_label(:in_progress), do: "In Progress"
  defp status_label(status), do: status |> to_string() |> String.capitalize()
end
