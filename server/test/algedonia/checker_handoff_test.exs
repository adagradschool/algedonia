defmodule Algedonia.CheckerHandoffTest do
  use ExUnit.Case, async: true

  alias Algedonia.CheckerHandoff

  test "validate/4 accepts valid payload" do
    loop_id = "loop-123"
    attempt = 2
    workspace_slug = "my-workspace"
    expected = CheckerHandoff.expected_paths(loop_id, attempt, workspace_slug)

    payload = %{
      "handoff_valid" => true,
      "verdict" => "pass",
      "feedback" => "All rubric checks passed.",
      "feedback_path" => expected.feedback
    }

    assert {:ok, result} = CheckerHandoff.validate(loop_id, attempt, workspace_slug, payload)
    assert result.verdict == "pass"
    assert result.feedback == "All rubric checks passed."
    assert result.feedback_path == expected.feedback
  end

  test "validate/4 rejects invalid handoff marker" do
    loop_id = "loop-123"
    attempt = 1
    workspace_slug = "my-workspace"

    payload = %{
      "handoff_valid" => false,
      "handoff_error" => "missing checker_result.json",
      "verdict" => "pass",
      "feedback" => "ignored",
      "feedback_path" =>
        ".algedonia/workspaces/my-workspace/handoffs/loop-123/attempt-1/checker_feedback.md"
    }

    assert {:error, "missing checker_result.json"} =
             CheckerHandoff.validate(loop_id, attempt, workspace_slug, payload)
  end

  test "expected_paths/3 uses workspace-scoped path" do
    paths = CheckerHandoff.expected_paths("loop-ws", 1, "my-workspace")

    expected_base =
      Path.join([
        "~",
        ".algedonia",
        "workspaces",
        "my-workspace",
        "handoffs",
        "loop-ws",
        "attempt-1"
      ])

    assert paths.json == Path.join(expected_base, "checker_result.json")
    assert paths.feedback == Path.join(expected_base, "checker_feedback.md")
  end

  test "validate/4 rejects missing workspace slug" do
    payload = %{"handoff_valid" => true, "verdict" => "pass", "feedback" => "ok"}
    assert {:error, _} = CheckerHandoff.validate("loop-ws", 1, nil, payload)
    assert {:error, _} = CheckerHandoff.validate("loop-ws", 1, "", payload)
  end

  test "validate/4 rejects feedback path mismatch" do
    loop_id = "loop-123"
    attempt = 3
    workspace_slug = "my-workspace"

    payload = %{
      "handoff_valid" => true,
      "verdict" => "fail",
      "feedback" => "Needs fixes",
      "feedback_path" =>
        ".algedonia/workspaces/my-workspace/handoffs/other-loop/attempt-3/checker_feedback.md"
    }

    assert {:error, msg} = CheckerHandoff.validate(loop_id, attempt, workspace_slug, payload)
    assert msg =~ "feedback path mismatch"
  end
end
