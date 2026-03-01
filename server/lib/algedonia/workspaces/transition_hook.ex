defmodule Algedonia.Workspaces.TransitionHook do
  @moduledoc """
  Schema for a workspace-level transition hook — fires an agent when a
  ticket moves between specific statuses.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :id

  @statuses [:backlog, :planning, :in_progress, :halted, :completed, :archived]

  schema "transition_hooks" do
    field :from_status, Ecto.Enum, values: @statuses
    field :to_status, Ecto.Enum, values: @statuses
    field :instruction, :string
    field :enabled, :boolean, default: true

    belongs_to :workspace, Algedonia.Workspaces.Workspace

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  Builds a changeset for creating or updating a transition hook.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(hook, attrs) do
    hook
    |> cast(attrs, [:workspace_id, :from_status, :to_status, :instruction, :enabled])
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
end
