defmodule Algedonia.PromptBuilderTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.PromptBuilder

  describe "optional_section/2" do
    test "returns nil for nil content" do
      assert PromptBuilder.optional_section("Label", nil) == nil
    end

    test "returns nil for empty string" do
      assert PromptBuilder.optional_section("Label", "") == nil
    end

    test "returns formatted section for non-empty content" do
      assert PromptBuilder.optional_section("Rubric", "- check tests") == "Rubric:\n- check tests"
    end
  end

  describe "non_empty/1" do
    test "returns nil for empty string" do
      assert PromptBuilder.non_empty("") == nil
    end

    test "returns nil for nil" do
      assert PromptBuilder.non_empty(nil) == nil
    end

    test "returns value for non-empty string" do
      assert PromptBuilder.non_empty("hello") == "hello"
    end
  end

  describe "non_empty_list/1" do
    test "returns nil for empty list" do
      assert PromptBuilder.non_empty_list([]) == nil
    end

    test "returns list for non-empty list" do
      assert PromptBuilder.non_empty_list([1, 2]) == [1, 2]
    end
  end

  describe "ticket_reference/1" do
    test "returns number as string when present" do
      assert PromptBuilder.ticket_reference(%{
               number: 42,
               id: "11111111-1111-4111-8111-111111111111"
             }) ==
               "42"
    end

    test "returns id when number is nil" do
      id = "22222222-2222-4222-8222-222222222222"
      assert PromptBuilder.ticket_reference(%{number: nil, id: id}) == id
    end
  end

  describe "format_comments/1" do
    test "returns nil for empty list" do
      assert PromptBuilder.format_comments([]) == nil
    end

    test "formats comments with author and body" do
      comments = [
        %{author: "ada", body: "looks good", replies: []}
      ]

      result = PromptBuilder.format_comments(comments)
      assert result =~ "Ticket comments:"
      assert result =~ "[ada] looks good"
    end

    test "formats nested replies with indentation" do
      comments = [
        %{
          author: "ada",
          body: "parent",
          replies: [
            %{author: "bob", body: "reply", replies: []}
          ]
        }
      ]

      result = PromptBuilder.format_comments(comments)
      assert result =~ "- [ada] parent"
      assert result =~ "  - [bob] reply"
    end
  end

  describe "format_comment/2" do
    test "formats a comment at depth 0" do
      comment = %{author: "ada", body: "hello", replies: []}
      assert PromptBuilder.format_comment(comment, 0) == "- [ada] hello"
    end

    test "formats a comment at depth 1 with indentation" do
      comment = %{author: "bob", body: "reply", replies: []}
      assert PromptBuilder.format_comment(comment, 1) == "  - [bob] reply"
    end

    test "handles unloaded replies" do
      comment = %{author: "ada", body: "test", replies: %Ecto.Association.NotLoaded{}}
      assert PromptBuilder.format_comment(comment, 0) == "- [ada] test"
    end
  end

  describe "maker_task/3" do
    test "builds maker prompt with ticket and task info" do
      loop = %{
        id: Ecto.UUID.generate(),
        title: "Implement feature",
        description: nil,
        rubric: "- must pass tests",
        current_attempt: 1
      }

      ticket = %{
        id: Ecto.UUID.generate(),
        number: 5,
        title: "Add auth",
        acceptance_criteria: "- login works",
        rubric: nil
      }

      result = PromptBuilder.maker_task(loop, ticket, "")

      assert result =~ "Ticket: Add auth"
      assert result =~ "Acceptance criteria:\n- login works"
      assert result =~ "Task:\nImplement feature"
      assert result =~ "Rubric:\n- must pass tests"
      assert result =~ "Implement the task and run relevant checks before finishing."
    end

    test "includes previous feedback when provided" do
      loop = %{
        id: Ecto.UUID.generate(),
        title: "Fix bug",
        description: nil,
        rubric: nil,
        current_attempt: 2
      }

      ticket = %{
        id: Ecto.UUID.generate(),
        number: nil,
        title: "Bug fix",
        acceptance_criteria: nil,
        rubric: nil
      }

      result = PromptBuilder.maker_task(loop, ticket, "Missing tests")
      assert result =~ "Checker Feedback:\nMissing tests"
    end
  end

  describe "checker_task/3" do
    test "builds checker prompt with handoff format" do
      loop = %{
        id: Ecto.UUID.generate(),
        title: "Check work",
        description: nil,
        rubric: "- quality check",
        current_attempt: 1
      }

      ticket = %{
        title: "Feature",
        acceptance_criteria: "- works",
        rubric: nil
      }

      result = PromptBuilder.checker_task(loop, ticket, "testspace")

      assert result =~ "Ticket: Feature"
      assert result =~ "REQUIRED HANDOFF FORMAT"
      assert result =~ "VERDICT"
      assert result =~ "\"commit_title\":\"<single-line summary>\""
      assert result =~ "non-empty single-line plain-text summary"
      assert result =~ "Rubric:\n- quality check"
      refute result =~ "ag ticket comments"
    end
  end

  describe "checker_handoff_repair_task/4" do
    test "builds repair prompt with error and round number" do
      loop = %{
        id: Ecto.UUID.generate(),
        current_attempt: 1
      }

      result = PromptBuilder.checker_handoff_repair_task(loop, "missing json", 2, "testspace")

      assert result =~ "repair round 2"
      assert result =~ "missing json"
      assert result =~ "REPAIR-ONLY MODE"
      assert result =~ "REQUIRED HANDOFF FORMAT"
      assert result =~ "\"commit_title\":\"<single-line summary>\""
      assert result =~ "non-empty single-line plain-text summary"
    end
  end

  describe "planning_session_task/1" do
    test "includes one-at-a-time requirement clarification guidance" do
      ticket = %{
        title: "Plan ticket",
        description: "Current scope",
        acceptance_criteria: "- behaves correctly",
        rubric: "- verify with tests"
      }

      result = PromptBuilder.planning_session_task(ticket)

      assert result =~ "Resolve requirement clarity with the user before refining"

      assert result =~
               "If requirements are already clear and implementation-ready, skip to step 3."

      assert result =~ "ask clarifying questions one at a time"
      assert result =~ "product behavior, architecture, dependencies, and non-goals"
    end
  end
end
