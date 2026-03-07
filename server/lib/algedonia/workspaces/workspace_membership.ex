defmodule Algedonia.Workspaces.WorkspaceMembership do
  @moduledoc """
  Membership between users and workspaces.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @roles [:owner, :member]

  schema "workspace_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :member

    belongs_to :workspace, Algedonia.Workspaces.Workspace
    belongs_to :user, Algedonia.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:workspace_id, :user_id, :role])
    |> validate_required([:workspace_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> check_constraint(:role, name: :valid_role)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:workspace_id, :user_id])
  end
end
