defmodule Algedonia.Workspaces.WorkspaceInvitation do
  @moduledoc """
  Schema for workspace invitations sent to GitHub usernames.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :id

  schema "workspace_invitations" do
    field :github_username, :string
    field :status, Ecto.Enum, values: [:pending, :accepted, :cancelled], default: :pending

    belongs_to :workspace, Algedonia.Workspaces.Workspace
    belongs_to :invited_by, Algedonia.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a workspace invitation.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:github_username, :status, :workspace_id, :invited_by_id])
    |> validate_required([:github_username, :workspace_id, :invited_by_id])
    |> validate_inclusion(:status, [:pending, :accepted, :cancelled])
    |> update_change(:github_username, &String.downcase/1)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:invited_by_id)
    |> unique_constraint([:workspace_id, :github_username],
      name: :workspace_invitations_pending_unique,
      message: "already has a pending invitation"
    )
  end
end
