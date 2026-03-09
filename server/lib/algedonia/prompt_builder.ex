defmodule Algedonia.PromptBuilder do
  @moduledoc """
  Pure functions for building prompt strings sent to planner, maker, checker,
  hooks, and checker handoff repair agents.
  """

  require EEx

  alias Algedonia.{CheckerHandoff, InlineReviews, Tickets}

  @doc """
  Builds the maker task prompt for a loop.

  Includes ticket context, acceptance criteria, comments, checker skills,
  task description, rubric, previous feedback, and inline reviews.
  """
  @spec maker_task(map(), map(), String.t()) :: String.t()
  def maker_task(loop, ticket, feedback) do
    task_desc = loop.description || loop.title
    checker_config = Map.get(loop, :checker_config)

    inline_reviews =
      loop.id
      |> InlineReviews.list_pending_by_loop()
      |> InlineReviews.serialize_for_prompt()

    render_template!("maker_task", %{
      ticket_title: ticket.title,
      acceptance_criteria: non_empty(ticket.acceptance_criteria),
      comments: format_comments(Tickets.list_comments(ticket.id)),
      checker_skills: skill_config_text(checker_config),
      task_desc: task_desc,
      rubric: non_empty(loop.rubric || ticket.rubric),
      previous_feedback: non_empty(feedback),
      inline_reviews: inline_reviews
    })
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
    checker_config = Map.get(loop, :checker_config)

    render_template!("checker_task", %{
      ticket_title: ticket.title,
      acceptance_criteria: non_empty(ticket.acceptance_criteria),
      checker_skills: skill_config_text(checker_config),
      task_desc: task_desc,
      rubric: non_empty(loop.rubric || ticket.rubric),
      expected_feedback_path: expected.feedback,
      expected_json_path: expected.json
    })
  end

  @doc """
  Builds the review task prompt for the auto-land review loop.

  Includes ticket context, agent navigation link, and previous review feedback.
  """
  @spec review_task(map(), map(), String.t() | nil, String.t() | nil) :: String.t()
  def review_task(loop, ticket, feedback, agent_link \\ nil) do
    task_desc = loop.description || loop.title

    render_template!("review_task", %{
      ticket_title: ticket.title,
      acceptance_criteria: non_empty(ticket.acceptance_criteria),
      comments: format_comments(Tickets.list_comments(ticket.id)),
      task_desc: task_desc,
      previous_feedback: non_empty(feedback),
      agent_link: non_empty(agent_link)
    })
  end

  @doc """
  Builds the planning-session task prompt used by ad-hoc planning loops.
  """
  @spec planning_session_task(map()) :: String.t()
  def planning_session_task(ticket) do
    render_template!("planning_session_task", %{
      ticket_title: ticket.title,
      description: non_empty(Map.get(ticket, :description)),
      acceptance_criteria: non_empty(Map.get(ticket, :acceptance_criteria)),
      current_rubric: non_empty(Map.get(ticket, :rubric))
    })
  end

  @doc """
  Builds the hook execution task prompt.
  """
  @spec hook_task(map()) :: String.t()
  def hook_task(context) do
    ticket = Map.get(context, :ticket) || %{}

    render_template!("hook_task", %{
      instruction: non_empty(Map.get(context, :instruction)) || "(no instruction provided)",
      ticket_id: Map.get(ticket, :id),
      ticket_title: Map.get(ticket, :title),
      ticket_status: Map.get(ticket, :status),
      previous_status: Map.get(ticket, :previous_status),
      acceptance_criteria: non_empty(Map.get(ticket, :acceptance_criteria)),
      description: non_empty(Map.get(ticket, :description))
    })
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

    render_template!("checker_handoff_repair_task", %{
      loop_id: loop.id,
      repairs: repairs,
      handoff_error: handoff_error,
      expected_feedback_path: expected.feedback,
      expected_json_path: expected.json
    })
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
  Returns nil when checker config is blank, otherwise pretty text for prompt inclusion.
  """
  @spec skill_config_text(any()) :: String.t() | nil
  def skill_config_text(nil), do: nil
  def skill_config_text(""), do: nil
  def skill_config_text(config) when is_binary(config), do: non_empty(String.trim(config))

  def skill_config_text(config) do
    inspect(config, pretty: true, limit: :infinity, width: 100)
  end

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

  # -- Private --

  defp render_template!(name, assigns) when is_map(assigns) do
    path =
      :algedonia
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("prompts/#{name}.md.eex")

    EEx.eval_file(path, Map.to_list(assigns), trim: true)
  end
end
