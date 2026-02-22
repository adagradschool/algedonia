defmodule AlgedoniaWeb.TicketComponents do
  @moduledoc """
  Reusable UI components for ticket rendering — cards, rows, icons, and badges.
  """
  use Phoenix.Component
  import AlgedoniaWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  Renders a status icon — a colored dot.
  """
  attr :status, :atom, required: true
  attr :class, :string, default: "size-2.5"

  def status_icon(assigns) do
    color = status_color(assigns.status)
    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={["inline-block rounded-full", @color, @class]} />
    """
  end

  @doc """
  Renders a priority icon — bars with varying fill levels.
  """
  attr :priority, :integer, required: true
  attr :class, :string, default: ""

  def priority_icon(assigns) do
    ~H"""
    <div
      class={["flex items-end gap-px", @class]}
      title={"Priority #{@priority}"}
    >
      <div class={["w-[3px] rounded-sm", bar_height(1), bar_fill(@priority, 1)]} />
      <div class={["w-[3px] rounded-sm", bar_height(2), bar_fill(@priority, 2)]} />
      <div class={["w-[3px] rounded-sm", bar_height(3), bar_fill(@priority, 3)]} />
      <div class={["w-[3px] rounded-sm", bar_height(4), bar_fill(@priority, 4)]} />
    </div>
    """
  end

  defp bar_height(1), do: "h-1"
  defp bar_height(2), do: "h-2"
  defp bar_height(3), do: "h-3"
  defp bar_height(4), do: "h-3.5"

  defp bar_fill(priority, bar) when 5 - priority >= bar, do: priority_bar_color(priority)
  defp bar_fill(_priority, _bar), do: "bg-fg-muted/20"

  defp priority_bar_color(_), do: "bg-fg-muted/70"

  @doc """
  Renders a type badge — colored dot + label pill.
  """
  attr :type, :atom, required: true

  def type_badge(assigns) do
    {dot_color, label} = type_meta(assigns.type)
    assigns = assign(assigns, dot_color: dot_color, label: label)

    ~H"""
    <span class="px-2 py-0.5 bg-surface-raised border border-border rounded-full text-[10px] text-fg-secondary flex items-center gap-1.5">
      <span class={["w-1.5 h-1.5 rounded-full", @dot_color]} />
      {@label}
    </span>
    """
  end

  defp type_meta(:feature), do: {"bg-accent-indigo", "Feature"}
  defp type_meta(:bug), do: {"bg-status-red", "Bug"}
  defp type_meta(:chore), do: {"bg-fg-muted", "Chore"}
  defp type_meta(:spike), do: {"bg-status-cyan", "Spike"}
  defp type_meta(type), do: {"bg-fg-muted", type |> to_string() |> String.capitalize()}

  @doc """
  Renders a ticket card for board view.
  """
  attr :ticket, :map, required: true
  attr :id, :string, required: true
  attr :prefix, :string, default: "AG"
  attr :workspace_slug, :string, default: nil

  def ticket_card(assigns) do
    ~H"""
    <div
      id={@id}
      data-ticket-id={@ticket.id}
      class="rounded-lg border border-border-soft bg-surface-panel p-3.5 space-y-2.5 cursor-pointer transition-all hover:border-border hover:bg-surface-raised"
      phx-click={JS.patch(workspace_path(@workspace_slug, "/tickets/#{@ticket.id}"))}
    >
      <div class="text-sm font-medium leading-snug text-fg">{@ticket.title}</div>
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <.priority_icon priority={@ticket.priority} />
          <span class="font-mono text-[10px] text-fg-muted">
            {ticket_code(@ticket, @prefix)}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <.type_badge type={@ticket.type} />
          <span
            :if={@ticket.assignee}
            class="text-[10px] text-fg-muted truncate max-w-16"
          >
            {@ticket.assignee}
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a ticket row for list view.
  """
  attr :ticket, :map, required: true
  attr :id, :string, required: true
  attr :prefix, :string, default: "AG"
  attr :workspace_slug, :string, default: nil

  def ticket_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex items-center gap-4 py-2.5 px-3.5 rounded-lg border border-transparent hover:border-border hover:bg-surface-raised transition-all cursor-pointer"
      phx-click={JS.patch(workspace_path(@workspace_slug, "/tickets/#{@ticket.id}"))}
    >
      <.priority_icon priority={@ticket.priority} />
      <span class="font-mono text-xs text-fg-muted w-16 shrink-0">
        {ticket_code(@ticket, @prefix)}
      </span>
      <.status_icon status={@ticket.status} />
      <span class="text-sm font-medium flex-1 truncate text-fg">
        {@ticket.title}
      </span>
      <.type_badge type={@ticket.type} />
      <span :if={@ticket.assignee} class="text-[10px] text-fg-muted w-16 text-right truncate">
        {@ticket.assignee}
      </span>
    </div>
    """
  end

  @doc """
  Renders a status column for board view with header and streamed ticket cards.
  """
  attr :status, :atom, required: true
  attr :count, :integer, required: true
  attr :stream, :any, required: true
  attr :prefix, :string, default: "AG"
  attr :workspace_slug, :string, default: nil

  def status_column(assigns) do
    label = status_label(assigns.status)
    assigns = assign(assigns, :label, label)

    ~H"""
    <div class="flex flex-col min-w-72 max-w-80 flex-1">
      <div class="flex items-center justify-between px-2 py-2 mb-1">
        <div class="flex items-center gap-2">
          <.status_icon status={@status} />
          <span class="text-xs font-medium text-fg-secondary">{@label}</span>
          <span class="text-[10px] text-fg-muted">{@count}</span>
        </div>
        <div class="flex items-center gap-1">
          <button
            class="size-6 rounded-md text-fg-muted hover:text-fg hover:bg-surface-raised transition-colors"
            phx-click={JS.patch(workspace_path(@workspace_slug, "/tickets/new?status=#{@status}"))}
            title="Add issue"
          >
            <.icon name="hero-plus-mini" class="size-4" />
          </button>
          <button
            class="size-6 rounded-md text-fg-muted hover:text-fg hover:bg-surface-raised transition-colors"
            title="Column options"
            type="button"
          >
            <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
          </button>
        </div>
      </div>
      <div
        id={"col-#{@status}"}
        phx-update="stream"
        data-kanban-column
        data-status={@status}
        class="flex flex-col gap-2 flex-1 overflow-y-auto"
      >
        <.ticket_card
          :for={{dom_id, ticket} <- @stream}
          ticket={ticket}
          id={dom_id}
          prefix={@prefix}
          workspace_slug={@workspace_slug}
        />
      </div>
    </div>
    """
  end

  @doc """
  Returns a human-readable label for a status atom.
  """
  def status_label(:backlog), do: "Backlog"
  def status_label(:decomposing), do: "Decomposing"
  def status_label(:halted), do: "Halted"
  def status_label(:in_progress), do: "In Progress"
  def status_label(:completed), do: "Completed"
  def status_label(:archived), do: "Archived"
  def status_label(status), do: status |> to_string() |> String.capitalize()

  defp status_color(:backlog), do: "bg-fg-muted"
  defp status_color(:decomposing), do: "bg-status-yellow"
  defp status_color(:halted), do: "bg-status-red"
  defp status_color(:in_progress), do: "bg-status-blue"
  defp status_color(:completed), do: "bg-status-green"
  defp status_color(:archived), do: "bg-fg-muted/50"
  defp status_color(_), do: "bg-fg-muted"

  defp ticket_code(%{number: number}, prefix) when is_integer(number),
    do: "#{prefix}-#{number}"

  defp ticket_code(ticket, _prefix), do: String.slice(ticket.id, 0, 8)

  defp workspace_path(nil, path), do: path
  defp workspace_path(slug, path), do: "/w/#{slug}#{path}"
end
