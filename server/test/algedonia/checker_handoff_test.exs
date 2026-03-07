defmodule Algedonia.CheckerHandoffTest do
  use ExUnit.Case, async: true

  alias Algedonia.CheckerHandoff

  test "validate/4 accepts valid payload" do
    loop_id = "11111111-1111-4111-8111-111111111111"
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
    loop_id = "11111111-1111-4111-8111-111111111111"
    attempt = 1
    workspace_slug = "my-workspace"

    payload = %{
      "handoff_valid" => false,
      "handoff_error" => "missing checker_result.json",
      "verdict" => "pass",
      "feedback" => "ignored",
      "feedback_path" =>
        ".algedonia/workspaces/my-workspace/handoffs/11111111-1111-4111-8111-111111111111/attempt-1/checker_feedback.md"
    }

    assert {:error, "missing checker_result.json"} =
             CheckerHandoff.validate(loop_id, attempt, workspace_slug, payload)
  end

  test "expected_paths/3 uses workspace-scoped path" do
    loop_id = "22222222-2222-4222-8222-222222222222"
    paths = CheckerHandoff.expected_paths(loop_id, 1, "my-workspace")

    expected_base =
      Path.join([
        "~",
        ".algedonia",
        "workspaces",
        "my-workspace",
        "handoffs",
        loop_id,
        "attempt-1"
      ])

    assert paths.json == Path.join(expected_base, "checker_result.json")
    assert paths.feedback == Path.join(expected_base, "checker_feedback.md")
  end

  test "validate/4 rejects missing workspace slug" do
    payload = %{"handoff_valid" => true, "verdict" => "pass", "feedback" => "ok"}
    loop_id = "33333333-3333-4333-8333-333333333333"
    assert {:error, _} = CheckerHandoff.validate(loop_id, 1, nil, payload)
    assert {:error, _} = CheckerHandoff.validate(loop_id, 1, "", payload)
  end

  test "validate/4 rejects feedback path mismatch" do
    loop_id = "11111111-1111-4111-8111-111111111111"
    attempt = 3
    workspace_slug = "my-workspace"

    payload = %{
      "handoff_valid" => true,
      "verdict" => "fail",
      "feedback" => "Needs fixes",
      "feedback_path" =>
        ".algedonia/workspaces/my-workspace/handoffs/44444444-4444-4444-8444-444444444444/attempt-3/checker_feedback.md"
    }

    assert {:error, msg} = CheckerHandoff.validate(loop_id, attempt, workspace_slug, payload)
    assert msg =~ "feedback path mismatch"
  end
end
