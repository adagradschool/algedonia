defmodule Algedonia.CheckerHandoff do
  @moduledoc """
  Contract and validation helpers for checker handoff payloads.

  Checker handoff is considered valid only when:
  - daemon marks `handoff_valid=true`
  - `verdict` is pass|fail
  - `feedback` is non-empty
  - `feedback_path` matches expected path for the loop
  """

  @type payload :: map()
  @type validated :: %{verdict: String.t(), feedback: String.t(), feedback_path: String.t() | nil}

  @spec expected_paths(binary(), pos_integer(), binary()) ::
          %{json: String.t(), feedback: String.t()}
  def expected_paths(loop_id, attempt, workspace_slug)
      when is_binary(workspace_slug) and workspace_slug != "" and is_integer(attempt) and
             attempt > 0 do
    base =
      Path.join([
        "~",
        ".algedonia",
        "workspaces",
        workspace_slug,
        "handoffs",
        loop_id,
        "attempt-#{attempt}"
      ])

    %{
      json: Path.join(base, "checker_result.json"),
      feedback: Path.join(base, "checker_feedback.md")
    }
  end

  @spec validate(binary(), pos_integer(), binary(), payload()) ::
          {:ok, validated()} | {:error, String.t()}
  def validate(loop_id, attempt, workspace_slug, payload)
      when is_binary(loop_id) and is_integer(attempt) and attempt > 0 and is_map(payload) and
             is_binary(workspace_slug) and workspace_slug != "" do
    expected = expected_paths(loop_id, attempt, workspace_slug)
    verdict = normalize_verdict(Map.get(payload, "verdict", ""))
    feedback = normalize_text(Map.get(payload, "feedback", ""))
    feedback_path = Map.get(payload, "feedback_path", nil)

    with :ok <- validate_handoff_marker(payload),
         :ok <- validate_verdict(verdict),
         :ok <- validate_feedback(feedback),
         :ok <- validate_feedback_path(feedback_path, expected.feedback) do
      {:ok, %{verdict: verdict, feedback: feedback, feedback_path: feedback_path}}
    end
  end

  def validate(_loop_id, _attempt, _workspace_slug, _payload),
    do: {:error, "workspace_slug is required for checker handoff validation"}

  defp validate_handoff_marker(payload) do
    if payload["handoff_valid"] == true do
      :ok
    else
      {:error, payload["handoff_error"] || "checker handoff files were not validated by daemon"}
    end
  end

  defp validate_verdict(verdict) when verdict in ["pass", "fail"], do: :ok
  defp validate_verdict(_), do: {:error, "checker verdict must be pass or fail"}

  defp validate_feedback(feedback) when feedback != "", do: :ok
  defp validate_feedback(_), do: {:error, "checker feedback markdown is empty"}

  defp validate_feedback_path(path, expected) do
    if expected_feedback_path?(path, expected) do
      :ok
    else
      {:error, "checker feedback path mismatch (expected #{expected})"}
    end
  end

  defp normalize_verdict(value), do: value |> to_string() |> String.downcase() |> String.trim()
  defp normalize_text(value), do: value |> to_string() |> String.trim()

  defp expected_feedback_path?(nil, _expected), do: false

  defp expected_feedback_path?(path, expected) do
    actual = path |> to_string() |> String.trim()

    suffix =
      expected
      |> String.trim_leading("~/")
      |> String.trim_leading("/")

    actual == expected or String.ends_with?(actual, suffix)
  end
end
