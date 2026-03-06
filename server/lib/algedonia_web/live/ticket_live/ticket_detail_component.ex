defmodule AlgedoniaWeb.TicketLive.TicketDetailComponent do
  @moduledoc """
  LiveComponent for the ticket detail panel — renders ticket form, comments,
  planning actions, and owns comment PubSub subscriptions.
  """
  use AlgedoniaWeb, :live_component

  alias Algedonia.Tickets

  import AlgedoniaWeb.CommentComponents

  @impl true
  def update(assigns, socket) do
    ticket = assigns[:ticket]
    subscribe_to_comments(socket, ticket)

    {:ok, assign(socket, assigns)}
  end

  defp subscribe_to_comments(socket, ticket) when not is_nil(ticket) do
    if connected?(socket) do
      old_ticket = socket.assigns[:ticket]

      if old_ticket && old_ticket.id != ticket.id do
        Phoenix.PubSub.unsubscribe(Algedonia.PubSub, "ticket:#{old_ticket.id}")
      end

      Tickets.subscribe_comments(ticket.id)
    end
  end

  defp subscribe_to_comments(_socket, _ticket), do: :ok

  def hook_status_classes(:passed), do: "bg-status-green/10 text-status-green"
  def hook_status_classes(:failed), do: "bg-status-red/10 text-status-red"
  def hook_status_classes(:running), do: "bg-status-blue/10 text-status-blue"
  def hook_status_classes(_), do: "bg-fg-muted/10 text-fg-muted"

  def format_hook_status(:running), do: "Running"
  def format_hook_status(status), do: status |> Atom.to_string() |> String.capitalize()

  def format_transition_status(:in_progress), do: "In Progress"
  def format_transition_status(status), do: status |> Atom.to_string() |> String.capitalize()

  attr :id, :string, required: true
  attr :field_key, :atom, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, required: true

  def ticket_detail_markdown_field(assigns) do
    ~H"""
    <div id={@id} data-shortcuts="off">
      <div class="text-xs font-medium text-fg-muted uppercase tracking-wide mb-2">
        {@label}
      </div>
      <div
        id={"#{@id}-editor"}
        phx-hook="MarkdownEditor"
        phx-update="ignore"
        data-push-event="autosave_ticket_markdown"
        data-field={@field_key}
        data-markdown={@value}
        data-placeholder={@placeholder}
        class="ticket-markdown-editor"
      />
    </div>
    """
  end
end
