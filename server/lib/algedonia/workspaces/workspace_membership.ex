defmodule Algedonia.Workspaces.WorkspaceMembership do
  @moduledoc """
  Membership between users and workspaces.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "workspace_memberships" do
    field :role, :string, default: "member"

    belongs_to :workspace, Algedonia.Workspaces.Workspace
    belongs_to :user, Algedonia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:workspace_id, :user_id, :role])
    |> validate_required([:workspace_id, :user_id, :role])
    |> unique_constraint([:workspace_id, :user_id])
  end
end
