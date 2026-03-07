defmodule Algedonia.Workspaces.Workspace do
  @moduledoc """
  Workspace schema for multi-tenant scoping.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @planning_modes [:auto, :always_approve, :always_review]

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :prefix, :string
    field :github_repo_url, :string
    field :tracker_config, :map, default: %{}
    field :playback_config, :map, default: %{}
    field :defaults, :map, default: %{}

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
      :planning_mode
    ])
    |> validate_required([:name, :slug, :prefix])
    |> validate_inclusion(:planning_mode, @planning_modes)
    |> check_constraint(:planning_mode, name: :workspaces_planning_mode_check)
    |> unique_constraint(:slug)
    |> validate_format(:github_repo_url, ~r{^https?://},
      message: "must be a valid URL starting with http:// or https://"
    )
  end
end
