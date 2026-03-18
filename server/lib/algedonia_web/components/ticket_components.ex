defmodule AlgedoniaWeb.TicketComponents do
  @moduledoc """
  Reusable UI components for ticket rendering — cards, rows, icons, and badges.
  """
  use Phoenix.Component
  import AlgedoniaWeb.CoreComponents, only: [icon: 1]
  import AlgedoniaWeb.Helpers, only: [ticket_ref: 1, short_id: 1]

  alias Algedonia.Tickets
  alias Phoenix.LiveView.JS

  @doc """
  Renders a status icon — a colored dot.
  """
  attr(:status, :atom, required: true)
  attr(:class, :string, default: "size-2.5")

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
  attr(:priority, :integer, required: true)
  attr(:class, :string, default: "")

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
  attr(:type, :atom, required: true)

  def type_badge(assigns) do
    {dot_color, label, badge_class} = type_meta(assigns.type)
    assigns = assign(assigns, dot_color: dot_color, label: label, badge_class: badge_class)

    ~H"""
    <span class={[
      "px-2 py-0.5 border rounded-full text-[10px] flex items-center gap-1.5",
      @badge_class
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full", @dot_color]} />
      {@label}
    </span>
    """
  end

  defp type_meta(:feature),
    do:
      {"bg-accent-indigo", "Feature",
       "bg-accent-indigo/10 border-accent-indigo/35 text-accent-indigo"}

  defp type_meta(:bug),
    do: {"bg-status-red", "Bug", "bg-status-red/10 border-status-red/35 text-status-red"}

  defp type_meta(:chore),
    do: {"bg-fg-muted", "Chore", "bg-surface-raised border-border text-fg-muted"}

  defp type_meta(:spike),
    do: {"bg-status-cyan", "Spike", "bg-status-cyan/10 border-status-cyan/35 text-status-cyan"}

  defp type_meta(type),
    do:
      {"bg-fg-muted", type |> to_string() |> String.capitalize(),
       "bg-surface-raised border-border text-fg-muted"}

  @doc """
  Renders a ticket card for board view.
  """
  attr(:ticket, :map, required: true)
  attr(:id, :string, required: true)
  attr(:prefix, :string, default: "AG")
  attr(:workspace_slug, :string, default: nil)
  attr(:loop_info, :map, default: %{})
  attr(:assignee_display_names, :map, default: %{})

  def ticket_card(assigns) do
    info = Map.get(assigns.loop_info, assigns.ticket.id, %{})
    action_loop_id = ticket_card_loop_id(assigns.ticket, info)

    assigns =
      assigns
      |> assign(:loop_id, action_loop_id)
      |> assign(:ticket_ref, ticket_ref(assigns.ticket))
      |> assign(:loop_ref, short_id(action_loop_id))
      |> assign(:stage, info[:stage])
      |> assign(:attempt, info[:attempt])

    ~H"""
    <div
      id={@id}
      data-ticket-id={@ticket.id}
      class="rounded-lg border border-border-soft bg-surface-panel p-3.5 space-y-2.5 cursor-pointer transition-all hover:border-border hover:bg-surface-raised"
      phx-click={JS.patch(workspace_path(@workspace_slug, "/tickets/#{@ticket_ref}"))}
    >
      <div class="text-sm font-medium leading-snug text-fg">{@ticket.title}</div>
      <.ticket_card_bottom_row
        ticket={@ticket}
        prefix={@prefix}
        workspace_slug={@workspace_slug}
        ticket_ref={@ticket_ref}
        loop_id={@loop_id}
        loop_ref={@loop_ref}
        stage={@stage}
        attempt={@attempt}
        assignee_display_names={@assignee_display_names}
      />
    </div>
    """
  end

  defp ticket_card_loop_id(%{status: :in_review}, info),
    do: info[:review_loop_id] || info[:loop_id]

  defp ticket_card_loop_id(_ticket, info), do: info[:loop_id]

  attr(:ticket, :map, required: true)
  attr(:prefix, :string, required: true)
  attr(:workspace_slug, :string, default: nil)
  attr(:ticket_ref, :string, required: true)
  attr(:loop_id, :string, default: nil)
  attr(:loop_ref, :string, default: nil)
  attr(:stage, :string, default: nil)
  attr(:attempt, :integer, default: nil)
  attr(:assignee_display_names, :map, default: %{})

  defp ticket_card_bottom_row(%{ticket: %{status: :in_review}} = assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2 flex-wrap">
      <div class="flex items-center gap-2 min-w-0">
        <.priority_icon priority={@ticket.priority} />
        <span class="font-mono text-[10px] text-fg-muted whitespace-nowrap">
          {ticket_code(@ticket, @prefix)}
        </span>
        <.type_badge type={@ticket.type} />
      </div>
      <div class="flex items-center gap-2 justify-end">
        <a
          :if={@loop_id}
          href={workspace_path(@workspace_slug, "/tickets/#{@ticket_ref}/loops/#{@loop_ref}")}
          phx-stop-propagation
          data-phx-link="redirect"
          data-phx-link-state="push"
          data-role="loop-stage-link"
          class="inline-flex items-center px-2 py-0.5 rounded-md border border-accent-indigo/40 bg-accent-indigo/10 text-accent-indigo text-[11px] font-medium hover:bg-accent-indigo/20 transition-colors"
        >
          Review
        </a>
      </div>
    </div>
    """
  end

  defp ticket_card_bottom_row(%{ticket: %{status: :in_progress}} = assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2 flex-wrap">
      <div class="flex items-center gap-2 min-w-0">
        <.priority_icon priority={@ticket.priority} />
        <span class="font-mono text-[10px] text-fg-muted whitespace-nowrap">
          {ticket_code(@ticket, @prefix)}
        </span>
        <.type_badge type={@ticket.type} />
      </div>
      <div class="flex items-center gap-2 justify-end">
        <a
          :if={@loop_id}
          href={workspace_path(@workspace_slug, "/tickets/#{@ticket_ref}/loops/#{@loop_ref}")}
          phx-stop-propagation
          data-phx-link="redirect"
          data-phx-link-state="push"
          data-role="loop-stage-link"
          class={[
            "inline-flex items-center px-2 py-0.5 rounded-md border text-[11px] font-medium transition-colors",
            stage_pill_classes(@stage)
          ]}
        >
          {stage_label(@stage || "maker", @attempt || 1)}
        </a>
      </div>
    </div>
    """
  end

  defp ticket_card_bottom_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2 flex-wrap">
      <div class="flex items-center gap-2">
        <.priority_icon priority={@ticket.priority} />
        <span class="font-mono text-[10px] text-fg-muted whitespace-nowrap">
          {ticket_code(@ticket, @prefix)}
        </span>
      </div>
      <div class="flex items-center gap-2 flex-wrap justify-end">
        <button
          :if={@ticket.status == :backlog}
          phx-click="plan_ticket"
          phx-value-id={@ticket.id}
          phx-stop-propagation
          class="inline-flex items-center px-2 py-0.5 rounded-md border border-status-yellow/40 bg-status-yellow/10 text-status-yellow text-[11px] font-medium hover:bg-status-yellow/20 transition-colors"
          type="button"
        >
          Plan
        </button>
        <button
          :if={@ticket.status == :planning}
          phx-click="open_planning_session"
          phx-value-id={@ticket.id}
          phx-stop-propagation
          class="inline-flex items-center px-2 py-0.5 rounded-md border border-status-yellow/40 bg-status-yellow/10 text-status-yellow text-[11px] font-medium hover:bg-status-yellow/20 transition-colors"
          type="button"
        >
          Plan Session
        </button>
        <button
          :if={@ticket.status in [:planning, :halted]}
          phx-click="start_work"
          phx-value-id={@ticket.id}
          phx-stop-propagation
          class="inline-flex items-center px-2 py-0.5 rounded-md border border-status-green/40 bg-status-green/10 text-status-green text-[11px] font-medium hover:bg-status-green/20 transition-colors"
          type="button"
        >
          Start Work
        </button>
        <a
          :if={@loop_id && @ticket.status != :planning}
          href={workspace_path(@workspace_slug, "/tickets/#{@ticket_ref}/loops/#{@loop_ref}")}
          phx-stop-propagation
          data-phx-link="redirect"
          data-phx-link-state="push"
          class="inline-flex items-center px-2 py-0.5 rounded-md border border-accent-indigo/40 bg-accent-indigo/10 text-accent-indigo text-[11px] font-medium hover:bg-accent-indigo/20 transition-colors"
        >
          Inspect
        </a>
        <.type_badge type={@ticket.type} />
        <span
          :if={@ticket.assignee}
          class="text-[10px] text-fg-muted max-w-36 whitespace-normal break-words text-right"
        >
          {Tickets.assignee_display_name(@assignee_display_names, @ticket.assignee)}
        </span>
      </div>
    </div>
    """
  end

  @doc """
  Renders a ticket row for list view.
  """
  attr(:ticket, :map, required: true)
  attr(:id, :string, required: true)
  attr(:prefix, :string, default: "AG")
  attr(:workspace_slug, :string, default: nil)
  attr(:loop_info, :map, default: %{})
  attr(:assignee_display_names, :map, default: %{})

  def ticket_row(assigns) do
    info = Map.get(assigns.loop_info, assigns.ticket.id, %{})

    assigns =
      assigns
      |> assign(:loop_id, info[:loop_id])
      |> assign(:ticket_ref, ticket_ref(assigns.ticket))
      |> assign(:loop_ref, short_id(info[:loop_id]))

    ~H"""
    <div
      id={@id}
      class="flex items-start gap-3 min-h-11 px-3.5 py-2 rounded-lg border border-transparent hover:border-border hover:bg-surface-raised transition-all cursor-pointer"
      phx-click={JS.patch(workspace_path(@workspace_slug, "/tickets/#{@ticket_ref}"))}
    >
      <.priority_icon priority={@ticket.priority} />
      <span class="font-mono text-xs text-fg-muted w-16 shrink-0 whitespace-nowrap">
        {ticket_code(@ticket, @prefix)}
      </span>
      <.status_icon status={@ticket.status} />
      <span class="text-sm font-medium flex-1 min-w-0 whitespace-normal break-words leading-snug text-fg">
        {@ticket.title}
      </span>
      <.type_badge type={@ticket.type} />
      <button
        :if={@ticket.status == :backlog}
        phx-click="plan_ticket"
        phx-value-id={@ticket.id}
        phx-stop-propagation
        class="inline-flex items-center px-2 py-1 rounded-md border border-status-yellow/40 bg-status-yellow/10 text-status-yellow text-[11px] font-medium hover:bg-status-yellow/20 transition-colors shrink-0"
        type="button"
      >
        Plan
      </button>
      <button
        :if={@ticket.status == :planning}
        phx-click="open_planning_session"
        phx-value-id={@ticket.id}
        phx-stop-propagation
        class="inline-flex items-center px-2 py-1 rounded-md border border-status-yellow/40 bg-status-yellow/10 text-status-yellow text-[11px] font-medium hover:bg-status-yellow/20 transition-colors shrink-0"
        type="button"
      >
        Plan Session
      </button>
      <button
        :if={@ticket.status in [:planning, :halted]}
        phx-click="start_work"
        phx-value-id={@ticket.id}
        phx-stop-propagation
        class="inline-flex items-center px-2 py-1 rounded-md border border-status-green/40 bg-status-green/10 text-status-green text-[11px] font-medium hover:bg-status-green/20 transition-colors shrink-0"
        type="button"
      >
        Start Work
      </button>
      <a
        :if={@loop_id && @ticket.status != :planning}
        href={workspace_path(@workspace_slug, "/tickets/#{@ticket_ref}/loops/#{@loop_ref}")}
        phx-stop-propagation
        data-phx-link="redirect"
        data-phx-link-state="push"
        class="inline-flex items-center px-2 py-1 rounded-md border border-accent-indigo/40 bg-accent-indigo/10 text-accent-indigo text-[11px] font-medium hover:bg-accent-indigo/20 transition-colors shrink-0"
      >
        Inspect
      </a>
      <span
        :if={@ticket.assignee}
        class="text-[10px] text-fg-muted max-w-40 text-right whitespace-normal break-words"
      >
        {Tickets.assignee_display_name(@assignee_display_names, @ticket.assignee)}
      </span>
      <div class="dropdown dropdown-end shrink-0" phx-stop-propagation>
        <button
          type="button"
          class="size-7 flex items-center justify-center rounded-md text-fg-muted hover:text-fg hover:bg-surface-panel transition-colors"
          title="Issue actions"
          phx-stop-propagation
        >
          <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
        </button>
        <ul
          tabindex="0"
          class="dropdown-content menu bg-surface-raised border border-border rounded-lg z-10 w-40 p-1 shadow-lg mt-1"
        >
          <li>
            <button
              id={"duplicate_ticket_quick-#{@ticket.id}"}
              data-testid="duplicate_ticket_quick"
              phx-click="duplicate_ticket"
              phx-value-id={@ticket.id}
              class="text-xs rounded"
              type="button"
              phx-stop-propagation
            >
              Duplicate
            </button>
          </li>
          <li>
            <button
              id={"delete_ticket_quick-#{@ticket.id}"}
              data-testid="delete_ticket_quick"
              phx-click="confirm_delete"
              phx-value-id={@ticket.id}
              class="text-xs rounded text-status-red"
              type="button"
              phx-stop-propagation
            >
              Delete
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Renders a status column for board view with header and streamed ticket cards.
  """
  attr(:status, :atom, required: true)
  attr(:count, :integer, required: true)
  attr(:stream, :any, required: true)
  attr(:sort, :map, required: true)
  attr(:prefix, :string, default: "AG")
  attr(:workspace_slug, :string, default: nil)
  attr(:loop_info, :map, default: %{})
  attr(:assignee_display_names, :map, default: %{})
  attr(:last, :boolean, default: false)

  def status_column(assigns) do
    label = status_label(assigns.status)
    assigns = assign(assigns, :label, label)

    ~H"""
    <div class="flex flex-col min-w-72 max-w-80 flex-1">
      <div class="flex items-center justify-between px-2 py-2 mb-1">
        <div class="flex items-center gap-2">
          <.status_icon status={@status} />
          <span class={["text-xs font-medium", status_label_color(@status)]}>{@label}</span>
          <span class="text-[10px] text-fg-muted">{@count}</span>
        </div>
        <.status_sort_menu status={@status} sort={@sort} />
      </div>
      <div
        id={"col-#{@status}"}
        phx-update="stream"
        data-kanban-column
        data-status={@status}
        class={[
          "flex flex-col gap-2 flex-1 overflow-y-auto",
          !@last && "border-r border-border-soft/20 pr-4"
        ]}
      >
        <.ticket_card
          :for={{dom_id, ticket} <- @stream}
          ticket={ticket}
          id={dom_id}
          prefix={@prefix}
          workspace_slug={@workspace_slug}
          loop_info={@loop_info}
          assignee_display_names={@assignee_display_names}
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders a status header for list view with per-status sorting controls.
  """
  attr(:status, :atom, required: true)
  attr(:count, :integer, required: true)
  attr(:sort, :map, required: true)

  def status_section_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2 px-3 py-1.5">
      <div class="flex items-center gap-2">
        <.status_icon status={@status} />
        <span class="text-xs font-medium text-fg-secondary">{status_label(@status)}</span>
        <span class="text-[10px] text-fg-muted">{@count}</span>
      </div>
      <.status_sort_menu status={@status} sort={@sort} />
    </div>
    """
  end

  attr(:status, :atom, required: true)
  attr(:sort, :map, required: true)

  def status_sort_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end" phx-stop-propagation>
      <button
        id={"ticket-sort-#{@status}"}
        type="button"
        class="inline-flex items-center rounded-md border border-border px-2 py-1 text-[10px] text-fg-muted hover:text-fg hover:bg-surface-raised transition-colors"
        aria-label={"Sort #{status_label(@status)}: #{sort_summary_for_aria(@sort)}"}
        title={"Sort #{status_label(@status)}: #{sort_summary_for_aria(@sort)}"}
      >
        <.icon name="hero-arrows-up-down" class="size-3" />
      </button>
      <div
        tabindex="0"
        class="dropdown-content z-10 mt-1 w-48 rounded-lg border border-border bg-surface-raised p-1 shadow-lg"
      >
        <div class="px-2 py-1 text-[10px] font-medium uppercase tracking-[0.08em] text-fg-muted">
          Sort by
        </div>
        <div class="flex flex-col gap-0.5">
          <button
            :for={field <- sort_fields()}
            type="button"
            phx-click="set_status_sort"
            phx-value-status={@status}
            phx-value-sort_by={field}
            class={[
              "rounded-md px-2 py-1 text-left text-xs transition-colors",
              @sort.sort_by == field && "bg-accent-indigo/10 text-fg",
              @sort.sort_by != field && "text-fg-secondary hover:bg-surface-panel hover:text-fg"
            ]}
          >
            {sort_field_label(field)}
          </button>
        </div>
        <div class="px-2 py-1 pt-2 text-[10px] font-medium uppercase tracking-[0.08em] text-fg-muted">
          Direction
        </div>
        <div class="grid grid-cols-2 gap-1 px-1 pb-1">
          <button
            type="button"
            phx-click="set_status_sort"
            phx-value-status={@status}
            phx-value-sort_order="asc"
            class={[
              "rounded-md px-2 py-1 text-xs transition-colors",
              @sort.sort_order == :asc && "bg-accent-indigo/10 text-fg",
              @sort.sort_order != :asc && "text-fg-secondary hover:bg-surface-panel hover:text-fg"
            ]}
          >
            Asc
          </button>
          <button
            type="button"
            phx-click="set_status_sort"
            phx-value-status={@status}
            phx-value-sort_order="desc"
            class={[
              "rounded-md px-2 py-1 text-xs transition-colors",
              @sort.sort_order == :desc && "bg-accent-indigo/10 text-fg",
              @sort.sort_order != :desc && "text-fg-secondary hover:bg-surface-panel hover:text-fg"
            ]}
          >
            Desc
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp stage_pill_classes("checker"),
    do: "border-status-yellow/40 bg-status-yellow/10 text-status-yellow hover:bg-status-yellow/20"

  defp stage_pill_classes(_),
    do: "border-accent-indigo/40 bg-accent-indigo/10 text-accent-indigo hover:bg-accent-indigo/20"

  defp stage_label(stage, attempt), do: "#{String.capitalize(stage)} ##{attempt}"

  @doc """
  Returns a human-readable label for a status atom.
  """
  def status_label(:backlog), do: "Backlog"
  def status_label(:planning), do: "Planning"
  def status_label(:halted), do: "Halted"
  def status_label(:in_progress), do: "In Progress"
  def status_label(:in_review), do: "In Review"
  def status_label(:completed), do: "Completed"
  def status_label(:archived), do: "Archived"
  def status_label(status), do: status |> to_string() |> String.capitalize()

  defp status_label_color(:backlog), do: "text-fg-muted"
  defp status_label_color(:planning), do: "text-status-yellow"
  defp status_label_color(:halted), do: "text-status-red"
  defp status_label_color(:in_progress), do: "text-status-blue"
  defp status_label_color(:in_review), do: "text-status-cyan"
  defp status_label_color(:completed), do: "text-status-green"
  defp status_label_color(:archived), do: "text-fg-muted"
  defp status_label_color(_), do: "text-fg-secondary"

  defp status_color(:backlog), do: "bg-fg-muted"
  defp status_color(:planning), do: "bg-status-yellow"
  defp status_color(:halted), do: "bg-status-red"
  defp status_color(:in_progress), do: "bg-status-blue"
  defp status_color(:in_review), do: "bg-status-cyan"
  defp status_color(:completed), do: "bg-status-green"
  defp status_color(:archived), do: "bg-fg-muted/50"
  defp status_color(_), do: "bg-fg-muted"

  defp ticket_code(%{number: number}, prefix) when is_integer(number),
    do: "#{prefix}-#{number}"

  defp ticket_code(ticket, _prefix), do: short_id(ticket.id)

  defp sort_fields, do: [:priority, :inserted_at, :updated_at, :title]
  defp sort_field_label(:priority), do: "Priority"
  defp sort_field_label(:inserted_at), do: "Created"
  defp sort_field_label(:updated_at), do: "Updated"
  defp sort_field_label(:title), do: "Title"

  defp sort_summary_for_aria(%{sort_by: sort_by, sort_order: sort_order}),
    do: "#{sort_field_label(sort_by)} #{sort_direction_word(sort_order)}"

  defp sort_direction_word(:desc), do: "descending"
  defp sort_direction_word(_), do: "ascending"

  defp workspace_path(nil, path), do: path
  defp workspace_path(slug, path), do: "/w/#{slug}#{path}"
end
