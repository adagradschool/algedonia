defmodule AlgedoniaWeb.CommentComponents do
  @moduledoc """
  UI components for the ticket activity feed — comments, replies, and compose forms.
  """
  use Phoenix.Component

  @doc """
  Renders the full activity section for a ticket detail view.
  """
  attr :comments, :list, required: true
  attr :comment_form, :map, required: true
  attr :comment_form_id, :string, default: "new_comment"
  attr :reply_to, :string, default: nil
  attr :reply_form, :map, default: nil
  attr :ticket_id, :string, required: true
  attr :current_user, :string, default: "You"
  attr :created_at, :any, required: true

  def activity_feed(assigns) do
    ~H"""
    <div class="space-y-0 pt-2 border-t border-border">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-sm font-semibold text-fg">Activity</h3>
      </div>

      <%!-- Creation event --%>
      <div class="flex items-center gap-2.5 py-2.5">
        <div class="size-5 rounded-full bg-fg-muted/20 flex items-center justify-center flex-shrink-0">
          <span class="text-[8px] font-medium text-fg-muted">SY</span>
        </div>
        <span class="text-xs text-fg-muted">
          Created <.relative_time datetime={@created_at} />
        </span>
      </div>

      <%!-- Comments --%>
      <div :for={comment <- @comments} class="mb-1">
        <.comment_block
          comment={comment}
          reply_to={@reply_to}
          reply_form={@reply_form}
          current_user={@current_user}
        />
      </div>

      <%!-- Top-level compose form --%>
      <div class="mt-3">
        <.compose_form
          form={@comment_form}
          placeholder="Leave a comment..."
          submit_event="submit_comment"
          form_id={@comment_form_id}
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders a single comment with its replies.
  """
  attr :comment, :map, required: true
  attr :reply_to, :string, default: nil
  attr :reply_form, :map, default: nil
  attr :current_user, :string, default: "You"

  def comment_block(assigns) do
    ~H"""
    <div class="rounded-lg border border-border bg-surface-raised">
      <div class="px-3 py-2.5">
        <div class="flex items-center gap-2 mb-1.5">
          <.avatar name={@comment.author} />
          <span class="text-xs font-medium text-fg">{@comment.author}</span>
          <span class="text-xs text-fg-muted">
            <.relative_time datetime={@comment.inserted_at} />
          </span>
        </div>
        <div class="text-sm text-fg-secondary pl-7 max-w-none break-words comment-markdown">
          {render_markdown(@comment.body)}
        </div>
      </div>

      <%!-- Replies --%>
      <div :for={reply <- @comment.replies} class="px-3 py-2 ml-4 border-t border-border/50">
        <div class="flex items-center gap-2 mb-1">
          <.avatar name={reply.author} size="sm" />
          <span class="text-xs font-medium text-fg">{reply.author}</span>
          <span class="text-xs text-fg-muted">
            <.relative_time datetime={reply.inserted_at} />
          </span>
        </div>
        <div class="text-sm text-fg-secondary pl-6 max-w-none break-words comment-markdown">
          {render_markdown(reply.body)}
        </div>
      </div>

      <%!-- Reply compose --%>
      <div class="border-t border-border/50">
        <div :if={@reply_to == @comment.id && @reply_form}>
          <.compose_form
            form={@reply_form}
            placeholder="Leave a reply..."
            submit_event="submit_reply"
            form_id={"reply_#{@comment.id}"}
            compact
          />
        </div>
        <button
          :if={@reply_to != @comment.id}
          phx-click="start_reply"
          phx-value-comment-id={@comment.id}
          class="w-full flex items-center gap-2 px-3 py-2 text-xs text-fg-muted hover:text-fg-secondary transition-colors cursor-pointer"
        >
          <.avatar name={@current_user} size="sm" />
          <span>Leave a reply...</span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a compose form for writing comments or replies.
  """
  attr :form, :map, required: true
  attr :placeholder, :string, default: "Leave a comment..."
  attr :submit_event, :string, required: true
  attr :compact, :boolean, default: false
  attr :form_id, :string, default: "comment"

  def compose_form(assigns) do
    ~H"""
    <.form
      for={@form}
      phx-submit={@submit_event}
      class={[
        "flex items-start gap-2 group",
        !@compact && "rounded-lg border border-border bg-surface-raised px-3 py-2.5",
        @compact && "px-3 py-2"
      ]}
    >
      <input type="hidden" name={@form[:parent_id].name} value={@form[:parent_id].value} />
      <textarea
        name={@form[:body].name}
        placeholder={@placeholder}
        rows="1"
        phx-hook="AutoResize"
        id={"#{@form_id}_body"}
        class="flex-1 bg-transparent border-0 text-sm text-fg placeholder-fg-muted resize-none focus:ring-0 focus:outline-none p-0 min-h-[20px]"
      >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
      <div class="flex items-center gap-1.5 flex-shrink-0 pt-0.5">
        <button
          type="submit"
          class="size-6 rounded-full bg-status-orange flex items-center justify-center hover:bg-status-orange/80 transition-colors"
          title="Send"
        >
          <svg
            class="size-3 text-white"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="2.5"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M4.5 10.5L12 3m0 0l7.5 7.5M12 3v18"
            />
          </svg>
        </button>
      </div>
    </.form>
    """
  end

  @doc """
  Renders a user avatar with initials.
  """
  attr :name, :string, required: true
  attr :size, :string, default: "md"

  def avatar(assigns) do
    initials = initials(assigns.name)
    assigns = assign(assigns, :initials, initials)

    ~H"""
    <div class={[
      "rounded-full bg-status-orange/80 flex items-center justify-center flex-shrink-0",
      @size == "md" && "size-5",
      @size == "sm" && "size-4"
    ]}>
      <span class={[
        "font-medium text-white uppercase",
        @size == "md" && "text-[8px]",
        @size == "sm" && "text-[7px]"
      ]}>
        {@initials}
      </span>
    </div>
    """
  end

  @doc """
  Renders a relative timestamp (e.g., "2m ago", "1h ago").
  """
  attr :datetime, :any, required: true

  def relative_time(assigns) do
    text = relative_time_text(assigns.datetime)
    assigns = assign(assigns, :text, text)

    ~H"""
    <time datetime={to_string(@datetime)} title={to_string(@datetime)}>{@text}</time>
    """
  end

  defp initials(nil), do: "?"

  defp initials(name) do
    name
    |> String.split(~r/[\s_\-]+/)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp render_markdown(nil), do: ""

  defp render_markdown(body) do
    case MDEx.to_html(body, extension: [autolink: true, strikethrough: true, table: true]) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> body
    end
  end

  defp relative_time_text(nil), do: ""

  defp relative_time_text(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end
end
