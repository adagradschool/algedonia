defmodule Algedonia.PromptBuilder do
  @moduledoc """
  Pure functions for building prompt strings sent to maker, checker,
  and checker handoff repair agents.
  """

  alias Algedonia.{CheckerHandoff, InlineReviews, Tickets}

  @doc """
  Builds the maker task prompt for a loop.

  Includes ticket context, acceptance criteria, comments, planning lookup,
  task description, rubric, previous feedback, and inline reviews.
  """
  @spec maker_task(map(), map(), String.t()) :: String.t()
  def maker_task(loop, ticket, feedback) do
    task_desc = loop.description || loop.title
    ticket_ref = ticket_reference(ticket)
    plan_lookup = "ag ticket comments #{ticket_ref} --json"

    inline_reviews =
      loop.id
      |> InlineReviews.list_pending_by_loop()
      |> InlineReviews.serialize_for_prompt()

    sections = [
      "Ticket: #{ticket.title}",
      optional_section("Acceptance criteria", ticket.acceptance_criteria),
      format_comments(Tickets.list_comments(ticket.id)),
      """
      Fetch approved planning notes before implementation:
      #{plan_lookup}
      """,
      "Task:\n#{task_desc}",
      optional_section("Rubric", loop.rubric || ticket.rubric),
      optional_section("Previous checker feedback", non_empty(feedback)),
      inline_reviews,
      "Implement the task and run relevant checks before finishing."
    ]

    sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
  end

  @doc """
  Builds the checker task prompt for a loop.

  Includes ticket context, task description, rubric, and the required
  handoff file IPC format instructions.
  """
  @spec checker_task(map(), map(), binary() | nil) :: String.t()
  def checker_task(loop, ticket, workspace_slug \\ nil) do
    expected = CheckerHandoff.expected_paths(loop.id, loop.current_attempt, workspace_slug)
    task_desc = loop.description || loop.title

    sections = [
      "Ticket: #{ticket.title}",
      optional_section("Acceptance criteria", ticket.acceptance_criteria),
      "Task:\n#{task_desc}",
      optional_section("Rubric", loop.rubric || ticket.rubric),
      """
      REQUIRED HANDOFF FORMAT (file IPC):
      1) Write markdown feedback to: #{expected.feedback}
      2) Write JSON to: #{expected.json}

      JSON must be exactly:
      {"VERDICT":"pass|fail","FEEDBACK":"#{expected.feedback}"}

      Rules:
      - Create parent directories if they do not exist.
      - VERDICT must be either "pass" or "fail" (lowercase).
      - FEEDBACK must be the markdown file path above.
      - Do not output any alternative verdict format.\
      """
    ]

    sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
  end

  @doc """
  Builds the checker handoff repair prompt for a failed handoff.

  Instructs the agent to only fix the handoff file contract without
  re-evaluating the codebase.
  """
  @spec checker_handoff_repair_task(map(), String.t(), non_neg_integer(), binary() | nil) ::
          String.t()
  def checker_handoff_repair_task(loop, handoff_error, repairs, workspace_slug \\ nil) do
    expected = CheckerHandoff.expected_paths(loop.id, loop.current_attempt, workspace_slug)

    """
    Handoff verifier failed for checker loop #{loop.id} (repair round #{repairs}):
    #{handoff_error}

    REPAIR-ONLY MODE:
    - Do NOT rerun checks.
    - Do NOT re-evaluate the codebase.
    - Use your previous checker conclusion and feedback from this attempt.
    - Only fix the handoff file contract.

    REQUIRED HANDOFF FORMAT (file IPC):
    1) Write markdown feedback to: #{expected.feedback}
    2) Write JSON to: #{expected.json}
    JSON exactly: {"VERDICT":"pass|fail","FEEDBACK":"#{expected.feedback}"}

    Rules:
    - Create parent directories if missing.
    - VERDICT must be lowercase pass/fail.
    - FEEDBACK must match the exact markdown path above.
    """
  end

  @doc """
  Returns a formatted section string, or nil when content is blank.
  """
  @spec optional_section(String.t(), String.t() | nil) :: String.t() | nil
  def optional_section(_label, nil), do: nil
  def optional_section(_label, ""), do: nil
  def optional_section(label, content), do: "#{label}:\n#{content}"

  @doc """
  Returns nil for empty strings, the value otherwise.
  """
  @spec non_empty(String.t() | nil) :: String.t() | nil
  def non_empty(""), do: nil
  def non_empty(nil), do: nil
  def non_empty(s), do: s

  @doc """
  Returns nil for empty lists, the list otherwise.
  """
  @spec non_empty_list(list()) :: list() | nil
  def non_empty_list([]), do: nil
  def non_empty_list(list), do: list

  @doc """
  Returns a short reference string for a ticket (number or id).
  """
  @spec ticket_reference(map()) :: String.t()
  def ticket_reference(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  def ticket_reference(%{id: id}), do: id

  @doc """
  Formats ticket comments for display in a maker prompt.

  Returns nil when there are no comments.
  """
  @spec format_comments([map()]) :: String.t() | nil
  def format_comments([]), do: nil

  def format_comments(comments) do
    formatted =
      comments
      |> Enum.map_join("\n", &format_comment(&1, 0))

    """
    Ticket comments:
    #{formatted}

    """
  end

  @doc """
  Formats a single comment with indentation for nested replies.
  """
  @spec format_comment(map(), non_neg_integer()) :: String.t()
  def format_comment(comment, depth) do
    indent = String.duplicate("  ", depth)
    header = "#{indent}- [#{comment.author}] #{comment.body}"

    replies =
      case comment.replies do
        %Ecto.Association.NotLoaded{} -> ""
        [] -> ""
        replies -> "\n" <> Enum.map_join(replies, "\n", &format_comment(&1, depth + 1))
      end

    header <> replies
  end
end
