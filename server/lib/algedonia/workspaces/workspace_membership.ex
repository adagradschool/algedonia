defmodule Algedonia.Workspaces.WorkspaceMembership do
  @moduledoc """
  Membership between users and workspaces.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Algedonia.Accounts.User
  alias Algedonia.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Algedonia.Types.id(),
          role: :owner | :member,
          workspace_id: Algedonia.Types.id(),
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          user_id: Algedonia.Types.id(),
          user: User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }
  @roles [:owner, :member]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :member

    belongs_to :workspace, Algedonia.Workspaces.Workspace
    belongs_to :user, Algedonia.Accounts.User

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
