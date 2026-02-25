defmodule Algedonia.CheckerHandoffTest do
  use ExUnit.Case, async: true

  alias Algedonia.CheckerHandoff

  test "validate/2 accepts valid payload" do
    loop_id = "loop-123"
    expected = CheckerHandoff.expected_paths(loop_id)

    payload = %{
      "handoff_valid" => true,
      "verdict" => "pass",
      "feedback" => "All rubric checks passed.",
      "feedback_path" => expected.feedback
    }

    assert {:ok, result} = CheckerHandoff.validate(loop_id, payload)
    assert result.verdict == "pass"
    assert result.feedback == "All rubric checks passed."
    assert result.feedback_path == expected.feedback
  end

  test "validate/2 rejects invalid handoff marker" do
    loop_id = "loop-123"

    payload = %{
      "handoff_valid" => false,
      "handoff_error" => "missing checker_result.json",
      "verdict" => "pass",
      "feedback" => "ignored",
      "feedback_path" => ".algedonia/handoffs/loop-123/checker_feedback.md"
    }

    assert {:error, "missing checker_result.json"} = CheckerHandoff.validate(loop_id, payload)
  end

  test "validate/2 rejects feedback path mismatch" do
    loop_id = "loop-123"

    payload = %{
      "handoff_valid" => true,
      "verdict" => "fail",
      "feedback" => "Needs fixes",
      "feedback_path" => ".algedonia/handoffs/other-loop/checker_feedback.md"
    }

    assert {:error, msg} = CheckerHandoff.validate(loop_id, payload)
    assert msg =~ "feedback path mismatch"
  end
end
