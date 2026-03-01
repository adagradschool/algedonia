defmodule Algedonia.Tickets.MarkdownExport do
  @moduledoc """
  Renders a ticket struct as a markdown document.
  Operates on preloaded data only — no Repo calls.
  """

  alias Algedonia.Tickets.{Comment, Ticket}

  @doc """
  Renders a ticket (with preloaded comments) as a markdown string.

  Empty optional sections are omitted. Comments appear in chronological order
  with replies rendered as blockquotes under their parent.
  """
  @spec render(Ticket.t()) :: String.t()
  def render(%Ticket{} = ticket) do
    [
      heading(ticket),
      metadata_table(ticket),
      section("Description", ticket.description),
      section("Acceptance Criteria", ticket.acceptance_criteria),
      section("Rubric", ticket.rubric),
      section("Overview", ticket.overview),
      comments_section(ticket)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp heading(%Ticket{number: n, title: title}) when is_integer(n), do: "# ##{n}: #{title}"
  defp heading(%Ticket{title: title}), do: "# #{title}"

  defp metadata_table(%Ticket{} = t) do
    rows =
      [
        {"Status", format_status(t.status)},
        {"Type", t.type && to_string(t.type)},
        {"Priority", t.priority && "P#{t.priority}"},
        {"Assignee", t.assignee},
        {"Coding Agent", t.coding_agent && to_string(t.coding_agent)},
        {"Created", format_time(t.inserted_at)},
        {"Updated", format_time(t.updated_at)}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, v} -> "| #{k} | #{v} |" end)

    ["| Field | Value |", "|-------|-------|" | rows] |> Enum.join("\n")
  end

  defp format_status(nil), do: nil
  defp format_status(s), do: s |> to_string() |> String.replace("_", " ")

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp section(_title, nil), do: nil
  defp section(_title, ""), do: nil
  defp section(title, body), do: "## #{title}\n\n#{body}"

  defp comments_section(%Ticket{comments: comments}) when is_list(comments) do
    if comments == [], do: nil, else: "## Comments\n\n" <> render_comments(comments)
  end

  defp comments_section(_), do: nil

  defp render_comments(comments), do: Enum.map_join(comments, "\n\n", &render_comment/1)

  defp render_comment(%Comment{} = c) do
    header = "### #{c.author} (#{format_time(c.inserted_at)})"
    replies = render_replies(c)

    if replies,
      do: header <> "\n\n" <> c.body <> "\n\n" <> replies,
      else: header <> "\n\n" <> c.body
  end

  defp render_replies(%Comment{replies: replies}) when is_list(replies) and replies != [] do
    Enum.map_join(replies, "\n\n", &render_reply/1)
  end

  defp render_replies(_), do: nil

  defp render_reply(%Comment{} = c) do
    header = "> #### #{c.author} (#{format_time(c.inserted_at)})"
    body = c.body |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
    header <> "\n" <> body
  end
end
