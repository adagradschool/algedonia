defmodule Algedonia.Workspaces do
  @moduledoc """
  Context for workspaces and memberships.
  """
  import Ecto.Query

  alias Algedonia.Accounts.User
  alias Algedonia.Repo
  alias Algedonia.Workspaces.{Workspace, WorkspaceMembership}

  def get_workspace_by_slug!(slug), do: Repo.get_by!(Workspace, slug: slug)
  def get_workspace!(id), do: Repo.get!(Workspace, id)

  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  def ensure_membership(%Workspace{} = workspace, %User{} = user) do
    Repo.insert(
      WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
        workspace_id: workspace.id,
        user_id: user.id,
        role: "member"
      }),
      on_conflict: :nothing
    )
  end

  def get_membership(workspace_id, user_id) do
    Repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: user_id)
  end

  def next_ticket_number!(%Workspace{} = workspace) do
    Repo.transaction(fn ->
      locked =
        Workspace
        |> where([w], w.id == ^workspace.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      number = locked.next_ticket_number

      {:ok, _} =
        locked
        |> Workspace.changeset(%{next_ticket_number: number + 1})
        |> Repo.update()

      number
    end)
    |> case do
      {:ok, number} -> number
      {:error, _} -> workspace.next_ticket_number
    end
  end

  def prefix_for_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[^A-Za-z]/, "")
    |> String.slice(0, 3)
    |> String.upcase()
    |> case do
      "" -> "AG"
      prefix -> prefix
    end
  end
end
