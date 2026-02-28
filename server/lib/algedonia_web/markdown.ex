defmodule AlgedoniaWeb.Markdown do
  @moduledoc """
  Markdown rendering helpers for tickets and comments.
  """
  def render(nil), do: ""

  def render(text) when is_binary(text) do
    case MDEx.to_html(text,
           extension: [autolink: true, strikethrough: true, table: true, tasklist: true]
         ) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> text
    end
  end
end
