defmodule Algedonia.Accounts.User do
  @moduledoc """
  User schema for workspace membership.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :github_id, :integer
    field :github_username, :string
    field :avatar_url, :string

    has_many :workspace_memberships, Algedonia.Workspaces.WorkspaceMembership

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end

  def github_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :github_id, :github_username, :avatar_url])
    |> validate_required([:github_id, :github_username])
    |> unique_constraint(:github_id)
  end
end
