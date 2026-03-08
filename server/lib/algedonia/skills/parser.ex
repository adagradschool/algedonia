defmodule Algedonia.Skills.Parser do
  @moduledoc false

  alias Algedonia.Skills.{Error, Skill}

  @frontmatter_regex ~r/\A---\s*\n(?<frontmatter>[\s\S]*?)\n---(?:\n|\z)/

  @spec parse_file(String.t()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def parse_file(file) when is_binary(file) do
    file = Path.expand(file)

    with {:ok, content} <- File.read(file),
         {:ok, frontmatter} <- extract_frontmatter(content, file),
         {:ok, metadata} <- parse_frontmatter(frontmatter, file) do
      build_skill(metadata, file)
    end
  end

  defp extract_frontmatter(content, file) do
    case Regex.named_captures(@frontmatter_regex, content) do
      %{"frontmatter" => frontmatter} ->
        {:ok, frontmatter}

      _ ->
        {:error,
         Error.new(%{
           file: file,
           field: "frontmatter",
           code: "missing_frontmatter",
           message: "Missing YAML-style frontmatter delimited by ---"
         })}
    end
  end

  defp parse_frontmatter(frontmatter, file) do
    lines = String.split(frontmatter, "\n", trim: false)

    case parse_lines(lines, file) do
      {:ok, metadata, nil, _buffer} ->
        {:ok, metadata}

      {:ok, metadata, current_key, buffer} ->
        {:ok, Map.put(metadata, current_key, parse_block_value(buffer))}

      {:error, _} = error ->
        error
    end
  end

  defp parse_lines(lines, file) do
    Enum.with_index(lines, 1)
    |> Enum.reduce_while({:ok, %{}, nil, []}, fn {raw_line, line_number},
                                                 {:ok, metadata, key, buffer} ->
      line = String.trim_trailing(raw_line, "\r")

      cond do
        key && top_level_key_line?(line) ->
          flush_block_and_continue(metadata, key, buffer, line, file, line_number)

        key && block_line?(line) ->
          {:cont, {:ok, metadata, key, buffer ++ [strip_block_indent(line)]}}

        key ->
          {:halt,
           {:error,
            Error.new(%{
              file: file,
              field: key,
              code: "invalid_frontmatter_syntax",
              message: "Line #{line_number} must be indented to continue field #{inspect(key)}"
            })}}

        top_level_key_line?(line) ->
          continue_with_new_key(metadata, line, file, line_number)

        String.trim(line) == "" ->
          {:cont, {:ok, metadata, key, buffer}}

        true ->
          {:halt,
           {:error,
            Error.new(%{
              file: file,
              field: "frontmatter",
              code: "invalid_frontmatter_syntax",
              message: "Invalid frontmatter syntax on line #{line_number}: #{line}"
            })}}
      end
    end)
  end

  defp continue_with_new_key(metadata, line, file, line_number) do
    case parse_top_level_line(line) do
      {:ok, key, :block} ->
        {:cont, {:ok, metadata, key, []}}

      {:ok, key, value} ->
        {:cont, {:ok, Map.put(metadata, key, value), nil, []}}

      :error ->
        {:halt,
         {:error,
          Error.new(%{
            file: file,
            field: "frontmatter",
            code: "invalid_frontmatter_syntax",
            message: "Invalid frontmatter syntax on line #{line_number}: #{line}"
          })}}
    end
  end

  defp flush_block(metadata, key, buffer), do: Map.put(metadata, key, parse_block_value(buffer))

  defp flush_block_and_continue(metadata, key, buffer, line, file, line_number) do
    metadata
    |> flush_block(key, buffer)
    |> continue_with_new_key(line, file, line_number)
  end

  defp parse_top_level_line(line) do
    case Regex.run(~r/^([A-Za-z0-9_]+):(.*)$/, line, capture: :all_but_first) do
      [key, value] ->
        value = String.trim(value)

        if value == "" do
          {:ok, key, :block}
        else
          {:ok, key, parse_scalar(value)}
        end

      _ ->
        :error
    end
  end

  defp top_level_key_line?(line), do: Regex.match?(~r/^[A-Za-z0-9_]+:/, line)

  defp block_line?(line) do
    String.trim(line) == "" or String.starts_with?(line, " ") or String.starts_with?(line, "\t")
  end

  defp strip_block_indent(line) do
    line
    |> String.replace_prefix("  ", "")
    |> String.replace_prefix("\t", "")
  end

  defp parse_block_value(lines) do
    lines
    |> Enum.join("\n")
    |> String.trim()
  end

  defp parse_scalar(value) do
    cond do
      value in ["true", "false"] -> value == "true"
      value == "null" -> nil
      quoted?(value) -> unquote_string(value)
      integer_string?(value) -> String.to_integer(value)
      json_like?(value) -> maybe_json_decode(value)
      true -> value
    end
  end

  defp quoted?(value), do: quoted_with?(value, "\"") or quoted_with?(value, "'")

  defp quoted_with?(value, quote) do
    String.starts_with?(value, quote) and String.ends_with?(value, quote) and
      String.length(value) >= 2
  end

  defp unquote_string(value) do
    length = String.length(value)
    String.slice(value, 1, max(length - 2, 0))
  end

  defp integer_string?(value), do: Regex.match?(~r/^-?\d+$/, value)

  defp json_like?(value) do
    (String.starts_with?(value, "{") and String.ends_with?(value, "}")) or
      (String.starts_with?(value, "[") and String.ends_with?(value, "]"))
  end

  defp maybe_json_decode(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp build_skill(metadata, file) do
    with {:ok, name} <- required_string(metadata, "name", file),
         {:ok, description} <- required_string(metadata, "description", file) do
      {:ok,
       %Skill{
         name: name,
         description: description,
         file: file,
         params_schema: Map.get(metadata, "params_schema"),
         metadata: metadata
       }}
    end
  end

  defp required_string(metadata, field, file) do
    value = Map.get(metadata, field)

    cond do
      is_binary(value) and String.trim(value) != "" ->
        {:ok, String.trim(value)}

      is_nil(value) ->
        {:error,
         Error.new(%{
           file: file,
           field: field,
           code: "missing_required_field",
           message: "Missing required field #{field} in skill frontmatter"
         })}

      true ->
        {:error,
         Error.new(%{
           file: file,
           field: field,
           code: "invalid_field_type",
           message: "Field #{field} must be a non-empty string"
         })}
    end
  end
end
