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

  @spec expected_paths(binary()) :: %{json: String.t(), feedback: String.t()}
  def expected_paths(loop_id) do
    base = Path.join(["~", ".algedonia", "handoffs", loop_id])

    %{
      json: Path.join(base, "checker_result.json"),
      feedback: Path.join(base, "checker_feedback.md")
    }
  end

  @spec validate(binary(), payload()) :: {:ok, validated()} | {:error, String.t()}
  def validate(loop_id, payload) when is_binary(loop_id) and is_map(payload) do
    expected = expected_paths(loop_id)

    verdict =
      payload |> Map.get("verdict", "") |> to_string() |> String.downcase() |> String.trim()

    feedback = payload |> Map.get("feedback", "") |> to_string() |> String.trim()
    feedback_path = payload |> Map.get("feedback_path", nil)

    cond do
      payload["handoff_valid"] != true ->
        {:error, payload["handoff_error"] || "checker handoff files were not validated by daemon"}

      verdict not in ["pass", "fail"] ->
        {:error, "checker verdict must be pass or fail"}

      feedback == "" ->
        {:error, "checker feedback markdown is empty"}

      not expected_feedback_path?(feedback_path, expected.feedback) ->
        {:error, "checker feedback path mismatch (expected #{expected.feedback})"}

      true ->
        {:ok, %{verdict: verdict, feedback: feedback, feedback_path: feedback_path}}
    end
  end

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
