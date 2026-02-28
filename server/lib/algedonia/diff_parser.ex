defmodule Algedonia.DiffParser do
  @moduledoc """
  Pure-function parser for unified diff output into structured data.
  """

  @type diff_file :: %{
          path: String.t(),
          old_path: String.t() | nil,
          status: :added | :deleted | :modified | :renamed | :binary,
          hunks: [hunk()]
        }

  @type hunk :: %{
          header: String.t(),
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          new_start: non_neg_integer(),
          new_count: non_neg_integer(),
          lines: [line()]
        }

  @type line :: %{
          type: :context | :addition | :deletion,
          content: String.t(),
          old_line: non_neg_integer() | nil,
          new_line: non_neg_integer() | nil
        }

  @doc """
  Parses a unified diff string into a list of file diffs.

  Returns an empty list for nil, empty, or whitespace-only input.
  """
  @spec parse(String.t() | nil) :: [diff_file()]
  def parse(nil), do: []
  def parse(""), do: []

  def parse(diff_text) do
    if String.trim(diff_text) == "" do
      []
    else
      diff_text
      |> split_into_file_sections()
      |> Enum.map(&parse_file_section/1)
      |> Enum.reject(&is_nil/1)
    end
  end

  @doc """
  Extracts the surrounding diff hunk context for a given file path and line number.
  Returns the hunk text or an empty string if not found.
  """
  @spec extract_hunk_context([diff_file()], String.t(), non_neg_integer(), non_neg_integer()) ::
          String.t()
  def extract_hunk_context(files, file_path, line_number, context_lines \\ 3) do
    case Enum.find(files, &(&1.path == file_path)) do
      nil ->
        ""

      file ->
        case find_hunk_for_line(file.hunks, line_number) do
          nil -> ""
          hunk -> format_hunk_context(hunk, line_number, context_lines)
        end
    end
  end

  defp split_into_file_sections(text) do
    text
    |> String.split(~r/^(?=diff --git )/m)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp parse_file_section(section) do
    lines = String.split(section, "\n")

    case parse_file_header(lines) do
      nil -> nil
      {path, old_path, status, rest} -> build_file_diff(path, old_path, status, rest)
    end
  end

  defp parse_file_header([first | rest]) do
    case Regex.run(~r/^diff --git a\/(.+) b\/(.+)$/, first) do
      [_, old_path, new_path] ->
        {status, remaining} = detect_status(rest, old_path, new_path)
        {new_path, if(old_path != new_path, do: old_path), status, remaining}

      _ ->
        nil
    end
  end

  defp parse_file_header([]), do: nil

  defp detect_status(lines, _old_path, _new_path) do
    cond do
      has_line?(lines, "Binary files") ->
        {:binary, skip_headers(lines)}

      has_line?(lines, "new file mode") ->
        {:added, skip_headers(lines)}

      has_line?(lines, "deleted file mode") ->
        {:deleted, skip_headers(lines)}

      has_line?(lines, "rename from") ->
        {:renamed, skip_headers(lines)}

      true ->
        {:modified, skip_headers(lines)}
    end
  end

  defp has_line?(lines, prefix) do
    Enum.any?(lines, &String.starts_with?(&1, prefix))
  end

  defp skip_headers(lines) do
    Enum.drop_while(lines, fn line ->
      not String.starts_with?(line, "@@")
    end)
  end

  defp build_file_diff(path, old_path, :binary, _lines) do
    %{path: path, old_path: old_path, status: :binary, hunks: []}
  end

  defp build_file_diff(path, old_path, status, lines) do
    hunks = parse_hunks(lines)
    %{path: path, old_path: old_path, status: status, hunks: hunks}
  end

  defp parse_hunks([]), do: []

  defp parse_hunks(lines) do
    lines
    |> chunk_by_hunk_header()
    |> Enum.map(&parse_single_hunk/1)
    |> Enum.reject(&is_nil/1)
  end

  defp chunk_by_hunk_header(lines) do
    lines
    |> Enum.reduce([], &accumulate_hunk_line/2)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  defp accumulate_hunk_line(line, acc) do
    if String.starts_with?(line, "@@") do
      [[line] | acc]
    else
      append_to_current_hunk(acc, line)
    end
  end

  defp append_to_current_hunk([current | rest], line), do: [[line | current] | rest]
  defp append_to_current_hunk([], _line), do: []

  defp parse_single_hunk([header | body]) do
    case parse_hunk_header(header) do
      nil ->
        nil

      {old_start, old_count, new_start, new_count} ->
        lines = parse_hunk_lines(body, old_start, new_start)

        %{
          header: header,
          old_start: old_start,
          old_count: old_count,
          new_start: new_start,
          new_count: new_count,
          lines: lines
        }
    end
  end

  defp parse_single_hunk([]), do: nil

  defp parse_hunk_header(line) do
    case Regex.run(~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/, line) do
      [_, old_s, old_c, new_s, new_c] ->
        {to_int(old_s), to_int(old_c), to_int(new_s), to_int(new_c)}

      [_, old_s, "", new_s, new_c] ->
        {to_int(old_s), 1, to_int(new_s), to_int(new_c)}

      [_, old_s, old_c, new_s] ->
        {to_int(old_s), to_int(old_c), to_int(new_s), 1}

      [_, old_s, "", new_s] ->
        {to_int(old_s), 1, to_int(new_s), 1}

      _ ->
        nil
    end
  end

  defp parse_hunk_lines(lines, old_start, new_start) do
    {parsed, _, _} =
      Enum.reduce(lines, {[], old_start, new_start}, fn line, {acc, old_ln, new_ln} ->
        cond do
          String.starts_with?(line, "+") ->
            entry = %{
              type: :addition,
              content: String.slice(line, 1..-1//1),
              old_line: nil,
              new_line: new_ln
            }

            {[entry | acc], old_ln, new_ln + 1}

          String.starts_with?(line, "-") ->
            entry = %{
              type: :deletion,
              content: String.slice(line, 1..-1//1),
              old_line: old_ln,
              new_line: nil
            }

            {[entry | acc], old_ln + 1, new_ln}

          String.starts_with?(line, " ") ->
            entry = %{
              type: :context,
              content: String.slice(line, 1..-1//1),
              old_line: old_ln,
              new_line: new_ln
            }

            {[entry | acc], old_ln + 1, new_ln + 1}

          String.starts_with?(line, "\\") ->
            {acc, old_ln, new_ln}

          true ->
            {acc, old_ln, new_ln}
        end
      end)

    Enum.reverse(parsed)
  end

  defp find_hunk_for_line(hunks, line_number) do
    Enum.find(hunks, fn hunk ->
      Enum.any?(hunk.lines, fn line ->
        line.new_line == line_number || line.old_line == line_number
      end)
    end)
  end

  defp format_hunk_context(hunk, line_number, context_lines) do
    idx =
      Enum.find_index(hunk.lines, fn line ->
        line.new_line == line_number || line.old_line == line_number
      end) || 0

    start_idx = max(0, idx - context_lines)
    end_idx = min(length(hunk.lines) - 1, idx + context_lines)

    hunk.lines
    |> Enum.slice(start_idx..end_idx)
    |> Enum.map_join("\n", fn line ->
      prefix =
        case line.type do
          :addition -> "+"
          :deletion -> "-"
          :context -> " "
        end

      "#{prefix}#{line.content}"
    end)
  end

  defp to_int(str), do: String.to_integer(str)
end
