defmodule AlgedoniaWeb.TicketLive.TicketFormComponent do
  @moduledoc """
  LiveComponent for create/edit ticket modal form.
  """
  use AlgedoniaWeb, :live_component

  alias Algedonia.Tickets
  alias AlgedoniaWeb.TicketLive.ComboboxHelpers

  @impl true
  def update(%{ticket: ticket, action: action} = assigns, socket) do
    changeset = Tickets.change_ticket(ticket)
    workspace = Map.get(assigns, :workspace)
    assignee_options = (workspace && Tickets.list_assignee_options(workspace.id)) || []

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
     |> assign(:blocked_by_open, false)
     |> assign(:blocked_by_search, "")
     |> assign(:assignee_options, assignee_options)
     |> assign(:assignee_open, false)
     |> assign(:assignee_search, ticket.assignee || "")
     |> assign(:depends_on_expanded, action != :new)
     |> assign_new(:return_to, fn ->
       workspace_slug = Map.get(assigns, :workspace_slug)
       if workspace_slug, do: ~p"/w/#{workspace_slug}/tickets", else: "/tickets"
     end)
     |> assign_new(:workspace, fn -> nil end)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"ticket" => ticket_params}, socket) do
    blocked_by_changed? =
      ComboboxHelpers.blocker_selection_changed?(socket.assigns.form, ticket_params)

    changeset =
      socket.assigns.ticket
      |> Tickets.change_ticket(ticket_params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign_form(changeset)
      |> maybe_close_blocked_by(blocked_by_changed?)

    {:noreply, socket}
  end

  def handle_event("filter_blocked_by", %{"value" => query}, socket) do
    {:noreply, assign(socket, blocked_by_search: query, blocked_by_open: true)}
  end

  def handle_event("open_blocked_by", _params, socket) do
    {:noreply, assign(socket, :blocked_by_open, true)}
  end

  def handle_event("close_blocked_by", _params, socket) do
    {:noreply, assign(socket, :blocked_by_open, false)}
  end

  def handle_event("filter_assignee", %{"value" => query}, socket) do
    {:noreply, assign(socket, assignee_search: query, assignee_open: true)}
  end

  def handle_event("open_assignee", _params, socket) do
    {:noreply, assign(socket, :assignee_open, true)}
  end

  def handle_event("close_assignee", _params, socket) do
    {:noreply, assign(socket, :assignee_open, false)}
  end

  def handle_event("select_assignee", %{"assignee" => assignee}, socket) do
    changeset =
      socket.assigns.ticket
      |> Tickets.change_ticket(Map.put(current_form_params(socket), "assignee", assignee))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:assignee_open, false)
     |> assign(:assignee_search, assignee)
     |> assign_form(changeset)}
  end

  def handle_event("expand_depends_on", _params, socket) do
    {:noreply, assign(socket, :depends_on_expanded, true)}
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
    blocked_by = Ecto.Changeset.get_field(changeset, :blocked_by, [])
    blocked_by_error? = Keyword.has_key?(changeset.errors, :blocked_by)

    expand_depends_on? =
      socket.assigns.depends_on_expanded || blocked_by != [] || blocked_by_error?

    socket
    |> assign(:depends_on_expanded, expand_depends_on?)
    |> assign(:form, to_form(changeset))
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

  def selected_blocked_by_options(options, values) do
    selected_ids = MapSet.new(ComboboxHelpers.normalize_multi_value(values))

    Enum.filter(options, fn {_label, id} ->
      MapSet.member?(selected_ids, to_string(id))
    end)
  end

  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: "Assignee"
  attr :options, :list, default: []
  attr :open, :boolean, default: false
  attr :search, :string, default: ""
  attr :target, :any, default: nil
  attr :filter_event, :string, required: true
  attr :open_event, :string, required: true
  attr :close_event, :string, required: true
  attr :select_event, :string, required: true
  attr :search_input_class, :string, required: true
  attr :options_container_class, :string, required: true
  attr :option_class, :string, required: true
  attr :selected_option_class, :string, required: true
  attr :clear_button_class, :string, default: ""
  attr :clear_button_label, :string, default: "Clear"
  attr :no_matches_class, :string, default: ""
  attr :error_class, :string, default: "mt-1.5 flex gap-2 items-center text-sm text-error"

  def assignee_selector(assigns) do
    assigns =
      assign(
        assigns,
        :filtered_options,
        filtered_assignee_options(assigns.options, assigns.search)
      )

    ~H"""
    <div
      id={"#{@id}-wrapper"}
      class="fieldset mb-2"
      phx-click-away={@close_event}
      phx-target={@target}
    >
      <div class="flex items-center justify-between gap-3">
        <span :if={@label} class="label mb-1">{@label}</span>
        <button
          :if={(@field.value || "") != ""}
          id={"#{@id}-clear"}
          type="button"
          phx-click={@select_event}
          phx-target={@target}
          phx-value-assignee=""
          class={@clear_button_class}
        >
          {@clear_button_label}
        </button>
      </div>

      <input type="hidden" id={@field.id} name={@field.name} value={@field.value || ""} />

      <input
        id={"#{@id}-search"}
        type="text"
        value={@search}
        placeholder="Search members..."
        phx-focus={@open_event}
        phx-blur={@close_event}
        phx-keyup={@filter_event}
        phx-target={@target}
        class={@search_input_class}
      />

      <div
        :if={ComboboxHelpers.options_visible?(@open, @search) and @filtered_options != []}
        class={@options_container_class}
      >
        <button
          :for={{label, value} <- @filtered_options}
          id={assignee_option_id(@id, value)}
          type="button"
          phx-click={@select_event}
          phx-target={@target}
          phx-value-assignee={value}
          class={[
            @option_class,
            (@field.value || "") == value && @selected_option_class
          ]}
        >
          {label}
        </button>
      </div>

      <p
        :if={ComboboxHelpers.options_visible?(@open, @search) and @filtered_options == []}
        class={@no_matches_class}
      >
        No matching members
      </p>

      <p :for={msg <- Enum.map(@field.errors || [], &translate_error(&1))} class={@error_class}>
        {msg}
      </p>
    </div>
    """
  end

  def filtered_assignee_options(options, search) do
    query = search |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      options
    else
      Enum.filter(options, fn {label, _value} ->
        String.starts_with?(String.downcase(label), query)
      end)
    end
  end

  defp current_form_params(socket) do
    socket.assigns.form.source.params || %{}
  end

  defp maybe_close_blocked_by(socket, true), do: assign(socket, :blocked_by_open, false)
  defp maybe_close_blocked_by(socket, false), do: socket

  defp assignee_option_id(base_id, value) do
    suffix =
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/u, "-")
      |> String.trim("-")

    "#{base_id}-option-#{suffix}"
  end

  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:in_review), do: "In Review"
  defp status_label(status), do: status |> to_string() |> String.capitalize()
end
