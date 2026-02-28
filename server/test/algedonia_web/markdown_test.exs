defmodule AlgedoniaWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias AlgedoniaWeb.Markdown

  test "renders markdown tables to html tables" do
    markdown = """
    | Criterion | Score |
    |---|---|
    | Title format | 1.0 |
    """

    html = markdown |> Markdown.render() |> Phoenix.HTML.safe_to_string()

    assert html =~ "<table>"
    assert html =~ "<th>Criterion</th>"
    assert html =~ "<td>Title format</td>"
  end

  test "renders markdown task list items as checkboxes" do
    markdown = """
    - [x] completed
    - [ ] pending
    """

    html = markdown |> Markdown.render() |> Phoenix.HTML.safe_to_string()

    assert html =~ ~s(type="checkbox")
    assert html =~ "completed"
    assert html =~ "pending"
  end
end
