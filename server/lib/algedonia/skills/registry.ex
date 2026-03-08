defmodule Algedonia.Skills.Registry do
  @moduledoc """
  Read-only filesystem-backed registry for `.algedonia/skills/**/SKILL.md`.
  """

  alias Algedonia.Skills.{Error, Parser, Skill}

  @enforce_keys [:skills, :errors, :root]
  defstruct [:skills, :errors, :root]

  @type t :: %__MODULE__{
          skills: %{optional(String.t()) => Skill.t()},
          errors: [Error.t()],
          root: String.t()
        }

  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    root = opts[:skills_root] || default_root()
    root = Path.expand(root)

    if File.dir?(root) do
      {skills, errors} = load_skill_files(root)
      %__MODULE__{skills: skills, errors: errors, root: root}
    else
      %__MODULE__{
        skills: %{},
        errors: [
          Error.new(%{
            file: root,
            field: "skills_root",
            code: "skills_dir_not_found",
            message: "Skills directory not found: #{root}"
          })
        ],
        root: root
      }
    end
  end

  @spec list(t()) :: [Skill.t()]
  def list(%__MODULE__{} = registry) do
    registry.skills
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @spec get(t(), String.t()) :: Skill.t() | nil
  def get(%__MODULE__{} = registry, name) when is_binary(name) do
    Map.get(registry.skills, name)
  end

  @spec default_root() :: String.t()
  def default_root do
    Application.get_env(:algedonia, :skills_root) || discover_root(File.cwd!())
  end

  defp load_skill_files(root) do
    root
    |> skill_files()
    |> Enum.reduce({%{}, []}, fn file, {skills, errors} ->
      case Parser.parse_file(file) do
        {:ok, %Skill{name: name} = skill} ->
          insert_skill(skills, errors, file, name, skill)

        {:error, %Error{} = error} ->
          {skills, errors ++ [error]}
      end
    end)
  end

  defp insert_skill(skills, errors, file, name, skill) do
    case Map.fetch(skills, name) do
      :error ->
        {Map.put(skills, name, skill), errors}

      {:ok, existing} ->
        error =
          Error.new(%{
            file: file,
            field: "name",
            code: "duplicate_skill_name",
            message:
              "Skill name #{inspect(name)} already defined in #{existing.file}; duplicate excluded"
          })

        {skills, errors ++ [error]}
    end
  end

  defp skill_files(root) do
    root
    |> Path.join("**/SKILL.md")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp discover_root(start_dir) do
    candidate = Path.join(start_dir, ".algedonia/skills")
    parent = Path.dirname(start_dir)

    cond do
      File.dir?(candidate) ->
        candidate

      parent != start_dir ->
        discover_root(parent)

      true ->
        candidate
    end
  end
end
