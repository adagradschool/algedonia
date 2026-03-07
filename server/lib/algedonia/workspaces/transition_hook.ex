defmodule Algedonia.Workspaces.TransitionHook do
  @moduledoc """
  Schema for a workspace-level transition hook — fires an agent when a
  ticket moves between specific statuses.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Algedonia.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:backlog, :planning, :in_progress, :halted, :completed, :archived]

  schema "transition_hooks" do
    field :from_status, Ecto.Enum, values: @statuses
    field :to_status, Ecto.Enum, values: @statuses
    field :instruction, :string
    field :enabled, :boolean, default: true

    belongs_to :workspace, Algedonia.Workspaces.Workspace

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: Algedonia.Types.id(),
          workspace_id: Algedonia.Types.id(),
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          from_status: :backlog | :planning | :in_progress | :halted | :completed | :archived,
          to_status: :backlog | :planning | :in_progress | :halted | :completed | :archived,
          instruction: String.t(),
          enabled: boolean(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  @doc """
  Builds a changeset for creating or updating a transition hook.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(hook, attrs) do
    hook
    |> cast(attrs, [:workspace_id, :from_status, :to_status, :instruction, :enabled])
    |> update_change(:instruction, &normalize_instruction/1)
    |> validate_required([:workspace_id, :from_status, :to_status, :instruction])
    |> validate_inclusion(:from_status, @statuses)
    |> validate_inclusion(:to_status, @statuses)
    |> unique_constraint([:workspace_id, :from_status, :to_status],
      message: "a hook for this transition already exists"
    )
    |> foreign_key_constraint(:workspace_id)
  end

  @doc """
  Returns the list of valid ticket statuses for hooks.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Trims and dedents instruction text so heredoc indentation does not leak into UI.
  """
  @spec normalize_instruction(String.t() | nil) :: String.t() | nil
  def normalize_instruction(nil), do: nil

  def normalize_instruction(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> drop_outer_blank_lines()
    |> dedent_lines()
    |> Enum.join("\n")
    |> String.trim()
  end

  def normalize_instruction(other), do: to_string(other) |> normalize_instruction()

  defp dedent_lines(lines) do
    min_indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&leading_indent_width/1)
      |> Enum.min(fn -> 0 end)

    if min_indent > 0 do
      regex = ~r/^[ \t]{0,#{min_indent}}/
      Enum.map(lines, &Regex.replace(regex, &1, ""))
    else
      lines
    end
  end

  defp leading_indent_width(line) do
    [indent] = Regex.run(~r/^[ \t]*/, line)
    String.length(indent)
  end

  defp drop_outer_blank_lines(lines) do
    lines
    |> drop_leading_blank_lines()
    |> Enum.reverse()
    |> drop_leading_blank_lines()
    |> Enum.reverse()
  end

  defp drop_leading_blank_lines([line | rest]) do
    if String.trim(line) == "" do
      drop_leading_blank_lines(rest)
    else
      [line | rest]
    end
  end

  defp drop_leading_blank_lines([]), do: []
end
