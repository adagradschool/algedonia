defmodule AlgedoniaWeb.CommentComponents do
  @moduledoc """
  UI components for the ticket activity feed — comments, replies, and compose forms.
  """
  use Phoenix.Component
  import AlgedoniaWeb.Helpers, only: [relative_time_text: 1]

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
  attr :editing_comment_id, :string, default: nil
  attr :edit_form, :map, default: nil

  def activity_feed(assigns) do
    ~H"""
    <div class="space-y-0 pt-3 border-t border-border">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-sm font-semibold text-fg">Activity</h3>
      </div>

      <%!-- Creation event --%>
      <div class="flex items-center gap-2.5 py-2.5">
        <div class="size-6 rounded-full bg-surface-panel border border-border flex items-center justify-center flex-shrink-0">
          <span class="text-[9px] font-medium text-fg-muted">SY</span>
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
          editing_comment_id={@editing_comment_id}
          edit_form={@edit_form}
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
  attr :editing_comment_id, :string, default: nil
  attr :edit_form, :map, default: nil

  def comment_block(assigns) do
    ~H"""
    <div class="rounded-xl border border-border bg-surface-panel">
      <div class="px-3.5 py-3 group">
        <div class="flex items-center gap-2 mb-1.5">
          <.avatar name={@comment.author} />
          <span class="text-xs font-medium text-fg">{@comment.author}</span>
          <span class="text-xs text-fg-muted">
            <.relative_time datetime={@comment.inserted_at} />
          </span>
          <div class="ml-auto flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
            <button
              phx-click="edit_comment"
              phx-value-id={@comment.id}
              class="size-6 rounded-md flex items-center justify-center text-fg-muted hover:text-fg hover:bg-surface-raised transition-colors"
              title="Edit"
              type="button"
            >
              <svg
                class="size-3.5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L10.582 16.07a4.5 4.5 0 01-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 011.13-1.897l8.932-8.931z"
                />
              </svg>
            </button>
            <button
              phx-click="delete_comment"
              phx-value-id={@comment.id}
              data-confirm="Delete this comment?"
              class="size-6 rounded-md flex items-center justify-center text-fg-muted hover:text-red-400 hover:bg-surface-raised transition-colors"
              title="Delete"
              type="button"
            >
              <svg
                class="size-3.5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0"
                />
              </svg>
            </button>
          </div>
        </div>
        <div
          :if={@editing_comment_id != @comment.id}
          class="text-sm text-fg-secondary pl-7 max-w-none break-words markdown"
        >
          {AlgedoniaWeb.Markdown.render(@comment.body)}
        </div>
        <div :if={@editing_comment_id == @comment.id && @edit_form} class="pl-7">
          <.compose_form
            form={@edit_form}
            placeholder="Edit comment..."
            submit_event="update_comment"
            form_id={"edit_#{@comment.id}"}
          />
          <button
            phx-click="cancel_edit"
            class="text-xs text-fg-muted hover:text-fg mt-1 cursor-pointer"
          >
            Cancel
          </button>
        </div>
      </div>

      <%!-- Replies --%>
      <div
        :for={reply <- @comment.replies}
        class="px-3 py-2 ml-4 border-t border-border/50 group/reply"
      >
        <div class="flex items-center gap-2 mb-1">
          <.avatar name={reply.author} size="sm" />
          <span class="text-xs font-medium text-fg">{reply.author}</span>
          <span class="text-xs text-fg-muted">
            <.relative_time datetime={reply.inserted_at} />
          </span>
          <div class="ml-auto flex items-center gap-1 opacity-0 group-hover/reply:opacity-100 transition-opacity">
            <button
              phx-click="edit_comment"
              phx-value-id={reply.id}
              class="size-6 rounded-md flex items-center justify-center text-fg-muted hover:text-fg hover:bg-surface-raised transition-colors"
              title="Edit"
              type="button"
            >
              <svg
                class="size-3.5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L10.582 16.07a4.5 4.5 0 01-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 011.13-1.897l8.932-8.931z"
                />
              </svg>
            </button>
            <button
              phx-click="delete_comment"
              phx-value-id={reply.id}
              data-confirm="Delete this comment?"
              class="size-6 rounded-md flex items-center justify-center text-fg-muted hover:text-red-400 hover:bg-surface-raised transition-colors"
              title="Delete"
              type="button"
            >
              <svg
                class="size-3.5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0"
                />
              </svg>
            </button>
          </div>
        </div>
        <div
          :if={@editing_comment_id != reply.id}
          class="text-sm text-fg-secondary pl-6 max-w-none break-words markdown"
        >
          {AlgedoniaWeb.Markdown.render(reply.body)}
        </div>
        <div :if={@editing_comment_id == reply.id && @edit_form} class="pl-6">
          <.compose_form
            form={@edit_form}
            placeholder="Edit comment..."
            submit_event="update_comment"
            form_id={"edit_#{reply.id}"}
            compact
          />
          <button
            phx-click="cancel_edit"
            class="text-xs text-fg-muted hover:text-fg mt-1 cursor-pointer"
            type="button"
          >
            Cancel
          </button>
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
        !@compact && "rounded-xl border border-border bg-surface-panel px-3 py-2.5",
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
          class="size-7 rounded-full bg-accent-indigo flex items-center justify-center hover:bg-accent-indigo-hover transition-colors"
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
      "rounded-full bg-accent-indigo/80 flex items-center justify-center flex-shrink-0",
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
end
