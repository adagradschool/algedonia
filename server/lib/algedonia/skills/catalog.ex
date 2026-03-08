defmodule Algedonia.Skills.Catalog do
  @moduledoc """
  Read-only catalog payload for UI skill listings and selectors.
  """

  alias Algedonia.Skills.{Error, Registry, Skill}

  @type validation_status :: String.t()

  @type diagnostic :: %{
          file: String.t() | nil,
          field: String.t() | nil,
          path: String.t() | nil,
          index: non_neg_integer() | nil,
          code: String.t(),
          message: String.t()
        }

  @type entry :: %{
          id: String.t(),
          name: String.t(),
          type: String.t(),
          source_path: String.t(),
          validation_status: validation_status(),
          diagnostics: [diagnostic()]
        }

  @type load_error :: %{
          code: String.t(),
          message: String.t(),
          source_path: String.t() | nil
        }

  @type t :: %{
          root: String.t(),
          entries: [entry()],
          load_error: load_error() | nil
        }

  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    registry = Registry.load(opts)
    valid_entries = build_valid_entries(registry)
    invalid_entries = build_invalid_entries(registry, valid_entries)

    %{
      root: registry.root,
      entries: Enum.sort_by(valid_entries ++ invalid_entries, &{&1.name, &1.source_path}),
      load_error: find_load_error(registry.errors)
    }
  end

  defp build_valid_entries(registry) do
    registry
    |> Registry.list()
    |> Enum.map(fn skill ->
      %{
        id: "skill-" <> skill.name,
        name: skill.name,
        type: type_for(skill),
        source_path: skill.file,
        validation_status: "valid",
        diagnostics: []
      }
    end)
  end

  defp build_invalid_entries(registry, valid_entries) do
    valid_files = MapSet.new(Enum.map(valid_entries, & &1.source_path))

    registry.errors
    |> Enum.reject(&load_error?/1)
    |> Enum.group_by(& &1.file)
    |> Enum.reject(fn {file, _errors} -> is_nil(file) or MapSet.member?(valid_files, file) end)
    |> Enum.map(fn {file, errors} ->
      diagnostics = Enum.map(errors, &Error.to_map/1)

      %{
        id: "invalid-" <> Integer.to_string(:erlang.phash2(file)),
        name: infer_name(file),
        type: "unknown",
        source_path: file,
        validation_status: "invalid",
        diagnostics: diagnostics
      }
    end)
  end

  defp type_for(%Skill{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "type") do
      type when is_binary(type) and type != "" -> type
      _ -> "unspecified"
    end
  end

  defp type_for(_), do: "unspecified"

  defp infer_name(file) do
    file
    |> Path.dirname()
    |> Path.basename()
    |> case do
      "." -> Path.basename(file)
      "" -> Path.basename(file)
      name -> name
    end
  end

  defp find_load_error(errors) do
    case Enum.find(errors, &load_error?/1) do
      nil ->
        nil

      error ->
        %{
          code: error.code,
          message: error.message,
          source_path: error.file
        }
    end
  end

  defp load_error?(%Error{code: "skills_dir_not_found"}), do: true
  defp load_error?(_), do: false
end
