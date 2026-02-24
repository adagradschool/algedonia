defmodule Algedonia.Accounts do
  @moduledoc """
  Context for user accounts.
  """
  import Ecto.Query

  alias Algedonia.Accounts.User
  alias Algedonia.Repo
  alias Algedonia.Workspaces.{Workspace, WorkspaceMembership}

  def get_user(id), do: Repo.get(User, id)
  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_name(name) do
    Repo.get_by(User, name: name)
  end

  def get_or_create_user(%{name: name} = attrs) when is_binary(name) do
    case get_user_by_name(name) do
      nil ->
        %User{}
        |> User.changeset(attrs)
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  def get_or_create_user_from_github(%{github_id: github_id} = attrs) do
    case Repo.get_by(User, github_id: github_id) do
      nil ->
        %User{}
        |> User.github_changeset(attrs)
        |> Repo.insert()

      user ->
        user
        |> User.github_changeset(attrs)
        |> Repo.update()
    end
  end

  def list_workspaces_for_user(user_id) do
    Workspace
    |> join(:inner, [w], m in WorkspaceMembership, on: m.workspace_id == w.id)
    |> where([_w, m], m.user_id == ^user_id)
    |> Repo.all()
  end
end
