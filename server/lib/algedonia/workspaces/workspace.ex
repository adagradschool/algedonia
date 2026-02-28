defmodule Algedonia.Workspaces.Workspace do
  @moduledoc """
  Workspace schema for multi-tenant scoping.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :prefix, :string
    field :github_repo_url, :string
    field :next_ticket_number, :integer, default: 1

    has_many :tickets, Algedonia.Tickets.Ticket
    has_many :workspace_memberships, Algedonia.Workspaces.WorkspaceMembership
    has_many :invitations, Algedonia.Workspaces.WorkspaceInvitation

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a workspace.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :prefix, :next_ticket_number, :github_repo_url])
    |> validate_required([:name, :slug, :prefix])
    |> unique_constraint(:slug)
    |> validate_format(:github_repo_url, ~r{^https?://},
      message: "must be a valid URL starting with http:// or https://"
    )
  end
end
