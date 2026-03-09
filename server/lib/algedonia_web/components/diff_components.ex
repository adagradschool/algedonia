defmodule AlgedoniaWeb.DiffComponents do
  @moduledoc """
  Components for rendering unified diffs with inline review comments.
  """
  use AlgedoniaWeb, :html

  alias Algedonia.DiffParser
  alias Phoenix.HTML
  alias Phoenix.HTML.Engine

  attr :diff_content, :string, default: nil
  attr :diff_loading, :boolean, default: false
  attr :diff_error, :string, default: nil
  attr :inline_reviews, :list, default: []
  attr :inline_comment_form, :map, default: nil
  attr :loop_id, :string, required: true
  attr :has_daemon, :boolean, default: false
  attr :loop_started, :boolean, default: false
  attr :active, :boolean, default: false

  def diff_viewer(assigns) do
    assigns =
      assign(assigns, :parsed_files, DiffParser.parse(assigns.diff_content))

    ~H"""
    <div class="diff-viewer space-y-1">
      <div :if={@diff_loading && !@diff_content} class="space-y-2 p-3">
        <div class="h-3 w-5/6 rounded skeleton-block"></div>
        <div class="h-3 w-full rounded skeleton-block"></div>
        <div class="h-3 w-3/4 rounded skeleton-block"></div>
      </div>

      <div :if={@diff_error} class="p-3 text-xs text-status-red">
        {@diff_error}
      </div>

      <.diff_empty_state
        :if={!@diff_loading && !@diff_content && !@diff_error}
        has_daemon={@has_daemon}
        loop_started={@loop_started}
      />

      <div
        :if={@diff_content && @parsed_files == []}
        class="p-3 text-xs text-fg-muted"
      >
        No changes detected.
      </div>

      <div
        :for={file <- @parsed_files}
        class="border border-border rounded-md overflow-hidden"
      >
        <.diff_file_header file={file} />
        <.diff_file_body
          :if={file.status != :binary}
          file={file}
          inline_reviews={@inline_reviews}
          inline_comment_form={@inline_comment_form}
          loop_id={@loop_id}
        />
        <div :if={file.status == :binary} class="px-3 py-2 text-xs text-fg-muted bg-surface">
          Binary file changed
        </div>
      </div>
    </div>
    """
  end

  attr :has_daemon, :boolean, required: true
  attr :loop_started, :boolean, required: true

  defp diff_empty_state(assigns) do
    ~H"""
    <div class="p-3 text-xs text-fg-muted">
      <span :if={!@has_daemon}>No daemon connected.</span>
      <span :if={@has_daemon && !@loop_started}>Loop has not started yet.</span>
      <span :if={@has_daemon && @loop_started}>No diff available.</span>
    </div>
    """
  end

  attr :file, :map, required: true

  defp diff_file_header(assigns) do
    ~H"""
    <div class="px-3 py-1.5 bg-surface text-xs font-mono flex items-center gap-2 border-b border-border">
      <span class={[
        "px-1.5 py-0.5 rounded text-[10px] font-semibold uppercase",
        file_status_class(@file.status)
      ]}>
        {file_status_label(@file.status)}
      </span>
      <span class="text-fg-secondary truncate">{@file.path}</span>
      <span :if={@file.old_path} class="text-fg-muted">
        (was {@file.old_path})
      </span>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :inline_reviews, :list, required: true
  attr :inline_comment_form, :map, default: nil
  attr :loop_id, :string, required: true

  defp diff_file_body(assigns) do
    ~H"""
    <div
      :for={hunk <- @file.hunks}
      class="font-mono text-[11px] leading-tight"
    >
      <div class="px-3 py-0.5 text-fg-muted bg-surface-panel border-b border-border text-[10px]">
        {hunk.header}
      </div>
      <table class="w-full border-collapse">
        <tbody>
          <%= for line <- hunk.lines do %>
            <tr class={line_class(line.type)}>
              <td class="diff-line-number select-none text-right pr-1 pl-2 text-fg-subtle w-[4ch] align-top">
                {display_line_number(line)}
              </td>
              <td class="diff-gutter select-none w-[2ch] text-center align-top">
                <button
                  type="button"
                  phx-click="open_inline_comment"
                  phx-value-file_path={@file.path}
                  phx-value-line_number={line.new_line || line.old_line}
                  phx-value-line_type={line.type}
                  class="inline-flex items-center justify-center size-4 rounded opacity-0 group-hover/diff-line:opacity-100 hover:bg-accent-indigo/20 text-fg-muted hover:text-accent-indigo transition-opacity"
                  title="Add comment"
                >
                  <.icon name="hero-chat-bubble-left-mini" class="size-3" />
                </button>
              </td>
              <td class="diff-line-content pr-3 align-top">
                {diff_line_content(@file.path, line)}
              </td>
            </tr>
            <.inline_comment_row
              :if={
                comment_form_for_line?(
                  @inline_comment_form,
                  @file.path,
                  line.type,
                  line.new_line || line.old_line
                )
              }
              form={@inline_comment_form}
            />
            <%= for review <- reviews_for_line(@inline_reviews, @file.path, line.new_line || line.old_line) do %>
              <tr class="bg-accent-indigo/5">
                <td colspan="3" class="px-3 py-2">
                  <div class="flex items-start gap-2 text-xs">
                    <span class="shrink-0 px-1.5 py-0.5 rounded bg-accent-indigo/20 text-accent-indigo text-[10px] font-medium">
                      {review.author}
                    </span>
                    <span class="text-fg-secondary">{review.body}</span>
                    <span class={[
                      "shrink-0 px-1 py-0.5 rounded text-[9px] uppercase",
                      review_status_class(review.status)
                    ]}>
                      {review.status}
                    </span>
                  </div>
                </td>
              </tr>
            <% end %>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :form, :map, required: true

  defp inline_comment_row(assigns) do
    ~H"""
    <tr class="bg-accent-indigo/5">
      <td colspan="3" class="px-3 py-2" data-shortcuts="off">
        <form phx-submit="add_inline_comment" class="space-y-2">
          <input type="hidden" name="file_path" value={@form["file_path"]} />
          <input type="hidden" name="line_number" value={@form["line_number"]} />
          <textarea
            name="body"
            rows="2"
            class="w-full rounded-md border border-border bg-surface px-2 py-1.5 text-xs text-fg font-sans placeholder:text-fg-muted focus:border-accent-indigo focus:ring-1 focus:ring-accent-indigo"
            placeholder="Write your review comment..."
            autofocus
          />
          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="close_inline_comment"
              class="px-2 py-1 rounded text-[11px] text-fg-muted hover:text-fg transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-2 py-1 rounded bg-accent-indigo text-white text-[11px] font-medium hover:bg-accent-indigo/80 transition-colors"
            >
              Comment
            </button>
          </div>
        </form>
      </td>
    </tr>
    """
  end

  defp file_status_class(:added), do: "bg-status-green/20 text-status-green"
  defp file_status_class(:deleted), do: "bg-status-red/20 text-status-red"
  defp file_status_class(:renamed), do: "bg-status-yellow/20 text-status-yellow"
  defp file_status_class(_), do: "bg-accent-indigo/20 text-accent-indigo"

  defp file_status_label(:added), do: "A"
  defp file_status_label(:deleted), do: "D"
  defp file_status_label(:modified), do: "M"
  defp file_status_label(:renamed), do: "R"
  defp file_status_label(:binary), do: "B"

  defp line_class(:addition), do: "bg-status-green/10 group/diff-line"
  defp line_class(:deletion), do: "bg-status-red/10 group/diff-line"
  defp line_class(:context), do: "group/diff-line"

  defp line_prefix(:addition), do: "+"
  defp line_prefix(:deletion), do: "-"
  defp line_prefix(:context), do: " "

  defp diff_line_content(path, line) do
    classes =
      ["block m-0 p-0 whitespace-pre-wrap break-all leading-tight", diff_lang_class(path)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    escaped_content =
      (line_prefix(line.type) <> line.content)
      |> Engine.html_escape()
      |> IO.iodata_to_binary()

    HTML.raw("<code class=\"#{classes}\">#{escaped_content}</code>")
  end

  defp display_line_number(%{type: :deletion, old_line: old_line}), do: old_line || ""
  defp display_line_number(%{new_line: new_line}), do: new_line || ""

  defp diff_lang_class(path) do
    case Path.extname(path) do
      ".ex" -> "language-elixir"
      ".exs" -> "language-elixir"
      ".go" -> "language-go"
      ".js" -> "language-javascript"
      ".ts" -> "language-typescript"
      ".tsx" -> "language-typescript"
      ".jsx" -> "language-javascript"
      _ -> ""
    end
  end

  defp review_status_class(:pending), do: "bg-status-yellow/20 text-status-yellow"
  defp review_status_class(:addressed), do: "bg-accent-indigo/20 text-accent-indigo"
  defp review_status_class(:resolved), do: "bg-status-green/20 text-status-green"
  defp review_status_class(_), do: "bg-surface-panel text-fg-muted"

  defp comment_form_for_line?(nil, _file_path, _line_type, _line_number), do: false

  defp comment_form_for_line?(form, file_path, line_type, line_number) do
    form["file_path"] == file_path &&
      to_string(form["line_number"]) == to_string(line_number) &&
      to_string(form["line_type"]) == to_string(line_type)
  end

  defp reviews_for_line(reviews, file_path, line_number) do
    Enum.filter(reviews, fn r ->
      r.file_path == file_path && r.line_number == line_number
    end)
  end
end
