defmodule Algedonia.Workspaces.Workspace do
  @moduledoc """
  Workspace schema for multi-tenant scoping.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Algedonia.Tickets.Ticket
  alias Algedonia.Workspaces.{TransitionHook, WorkspaceInvitation, WorkspaceMembership}

  @type t :: %__MODULE__{
          id: Algedonia.Types.id(),
          name: String.t(),
          slug: String.t(),
          prefix: String.t(),
          github_repo_url: String.t() | nil,
          tracker_config: map(),
          playback_config: map(),
          defaults: map(),
          max_iterations: integer(),
          planning_mode: :auto | :always_approve | :always_review,
          next_ticket_number: integer(),
          tickets: [Ticket.t()] | Ecto.Association.NotLoaded.t(),
          workspace_memberships: [WorkspaceMembership.t()] | Ecto.Association.NotLoaded.t(),
          invitations: [WorkspaceInvitation.t()] | Ecto.Association.NotLoaded.t(),
          transition_hooks: [TransitionHook.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }
  @planning_modes [:auto, :always_approve, :always_review]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :prefix, :string
    field :github_repo_url, :string
    field :tracker_config, :map, default: %{}
    field :playback_config, :map, default: %{}
    field :defaults, :map, default: %{}
    field :max_iterations, :integer, default: 10

    field :planning_mode, Ecto.Enum,
      values: @planning_modes,
      default: :auto

    field :next_ticket_number, :integer, default: 1

    has_many :tickets, Algedonia.Tickets.Ticket
    has_many :workspace_memberships, Algedonia.Workspaces.WorkspaceMembership
    has_many :invitations, Algedonia.Workspaces.WorkspaceInvitation
    has_many :transition_hooks, Algedonia.Workspaces.TransitionHook

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a workspace.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [
      :name,
      :slug,
      :prefix,
      :next_ticket_number,
      :github_repo_url,
      :tracker_config,
      :playback_config,
      :defaults,
      :max_iterations,
      :planning_mode
    ])
    |> validate_required([:name, :slug, :prefix])
    |> validate_number(:max_iterations, greater_than: 0, less_than_or_equal_to: 50)
    |> validate_inclusion(:planning_mode, @planning_modes)
    |> check_constraint(:max_iterations, name: :workspaces_max_iterations_check)
    |> check_constraint(:planning_mode, name: :workspaces_planning_mode_check)
    |> unique_constraint(:slug)
    |> validate_format(:github_repo_url, ~r{^https?://},
      message: "must be a valid URL starting with http:// or https://"
    )
  end
end
