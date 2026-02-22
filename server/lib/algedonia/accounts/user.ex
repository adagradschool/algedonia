defmodule Algedonia.Accounts.User do
  @moduledoc """
  User schema for workspace membership.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string

    has_many :workspace_memberships, Algedonia.Workspaces.WorkspaceMembership

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_required([:name])
  end
end
