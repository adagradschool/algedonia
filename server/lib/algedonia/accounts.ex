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

  def get_or_create_user_from_github(%{github_id: _github_id} = attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %User{}
    |> User.github_changeset(attrs)
    |> Repo.insert(
      conflict_target: :github_id,
      on_conflict: [
        set: [
          github_username: Map.get(attrs, :github_username),
          name: Map.get(attrs, :name),
          email: Map.get(attrs, :email),
          avatar_url: Map.get(attrs, :avatar_url),
          updated_at: now
        ]
      ],
      returning: true
    )
  end

  def list_workspaces_for_user(user_id) do
    Workspace
    |> join(:inner, [w], m in WorkspaceMembership, on: m.workspace_id == w.id)
    |> where([_w, m], m.user_id == ^user_id)
    |> Repo.all()
  end
end
