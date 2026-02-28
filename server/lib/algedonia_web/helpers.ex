defmodule AlgedoniaWeb.Helpers do
  @moduledoc """
  Shared web-layer utilities for controllers and LiveViews.
  """

  @doc """
  Traverses changeset errors into a human-readable map.
  """
  @spec format_errors(Ecto.Changeset.t()) :: map()
  def format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
      |> sentence_case()
    end)
  end

  @doc """
  Puts `value` into `map` under `key` unless `value` is nil.
  """
  @spec maybe_put(map(), String.t(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Converts a human-readable name into a URL-friendly slug.

  Downcases, strips non-alphanumeric characters (except hyphens and spaces),
  collapses whitespace/hyphens into single hyphens, and trims leading/trailing
  hyphens. Returns `"workspace"` if the result would be empty.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "workspace"
      slug -> slug
    end
  end

  @spec sentence_case(String.t()) :: String.t()
  def sentence_case(""), do: ""

  def sentence_case(text) do
    case String.next_grapheme(text) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> text
    end
  end
end
