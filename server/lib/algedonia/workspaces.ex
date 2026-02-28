defmodule Algedonia.Workspaces do
  @moduledoc """
  Context for workspaces, memberships, and invitations.
  """
  import Ecto.Query

  alias Algedonia.Accounts.User
  alias Algedonia.Repo
  alias Algedonia.Workspaces.{Workspace, WorkspaceInvitation, WorkspaceMembership}

  @doc """
  Gets a workspace by slug, raising if not found.
  """
  @spec get_workspace_by_slug!(String.t()) :: Workspace.t()
  def get_workspace_by_slug!(slug), do: Repo.get_by!(Workspace, slug: slug)

  @doc """
  Gets a workspace by slug, returning nil if not found.
  """
  @spec get_workspace_by_slug(String.t()) :: Workspace.t() | nil
  def get_workspace_by_slug(slug), do: Repo.get_by(Workspace, slug: slug)

  @doc """
  Gets a workspace by ID, raising if not found.
  """
  @spec get_workspace!(integer()) :: Workspace.t()
  def get_workspace!(id), do: Repo.get!(Workspace, id)

  @doc """
  Returns a changeset for a workspace, suitable for `to_form/1`.
  """
  @spec change_workspace(Workspace.t(), map()) :: Ecto.Changeset.t()
  def change_workspace(%Workspace{} = workspace, attrs \\ %{}) do
    Workspace.changeset(workspace, attrs)
  end

  @doc """
  Creates a workspace with the given attributes.
  """
  @spec create_workspace(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a workspace with the given attributes.
  """
  @spec update_workspace(Workspace.t(), map()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def update_workspace(%Workspace{} = workspace, attrs) do
    workspace
    |> Workspace.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Ensures a membership exists for the user in the workspace.

  Uses `on_conflict: :nothing` so it's safe to call multiple times.
  """
  @spec ensure_membership(Workspace.t(), User.t()) ::
          {:ok, WorkspaceMembership.t()} | {:error, Ecto.Changeset.t()}
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

  @doc """
  Gets a membership for a user in a workspace, or nil.
  """
  @spec get_membership(integer(), integer()) :: WorkspaceMembership.t() | nil
  def get_membership(workspace_id, user_id) do
    Repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: user_id)
  end

  @doc """
  Lists all members of a workspace, returning user records.
  """
  @spec list_members(integer()) :: [User.t()]
  def list_members(workspace_id) do
    User
    |> join(:inner, [u], m in WorkspaceMembership, on: m.user_id == u.id)
    |> where([_u, m], m.workspace_id == ^workspace_id)
    |> order_by([u], u.name)
    |> Repo.all()
  end

  @doc """
  Removes a member from a workspace by deleting their membership.
  """
  @spec remove_member(integer(), integer()) ::
          {:ok, WorkspaceMembership.t()} | {:error, :not_found}
  def remove_member(workspace_id, user_id) do
    case get_membership(workspace_id, user_id) do
      nil -> {:error, :not_found}
      membership -> {:ok, Repo.delete!(membership)}
    end
  end

  @doc """
  Creates a pending invitation for a GitHub username in a workspace.

  The username is lowercased before storage.
  """
  @spec create_invitation(Workspace.t(), String.t(), User.t()) ::
          {:ok, WorkspaceInvitation.t()} | {:error, Ecto.Changeset.t()}
  def create_invitation(%Workspace{} = workspace, github_username, %User{} = invited_by) do
    %WorkspaceInvitation{}
    |> WorkspaceInvitation.changeset(%{
      workspace_id: workspace.id,
      github_username: github_username,
      invited_by_id: invited_by.id
    })
    |> Repo.insert()
  end

  @doc """
  Lists pending invitations for a workspace, preloading the inviter.
  """
  @spec list_invitations(integer()) :: [WorkspaceInvitation.t()]
  def list_invitations(workspace_id) do
    WorkspaceInvitation
    |> where([i], i.workspace_id == ^workspace_id and i.status == :pending)
    |> order_by([i], desc: i.inserted_at)
    |> preload(:invited_by)
    |> Repo.all()
  end

  @doc """
  Cancels a pending invitation by setting its status to `:cancelled`.
  """
  @spec cancel_invitation(String.t()) ::
          {:ok, WorkspaceInvitation.t()} | {:error, Ecto.Changeset.t()}
  def cancel_invitation(invitation_id) do
    invitation = Repo.get!(WorkspaceInvitation, invitation_id)

    invitation
    |> WorkspaceInvitation.changeset(%{status: :cancelled})
    |> Repo.update()
  end

  @doc """
  Accepts all pending invitations matching the user's GitHub username.

  For each matching invitation, creates a workspace membership and marks the
  invitation as accepted. Returns `{:ok, count}` with the number accepted.
  """
  @spec accept_pending_invitations(User.t()) :: {:ok, non_neg_integer()}
  def accept_pending_invitations(%User{github_username: nil}), do: {:ok, 0}

  def accept_pending_invitations(%User{} = user) do
    username = String.downcase(user.github_username)

    invitations =
      WorkspaceInvitation
      |> where([i], i.github_username == ^username and i.status == :pending)
      |> preload(:workspace)
      |> Repo.all()

    count =
      Enum.count(invitations, fn invitation ->
        case ensure_membership(invitation.workspace, user) do
          {:ok, _} ->
            invitation
            |> WorkspaceInvitation.changeset(%{status: :accepted})
            |> Repo.update!()

            true

          {:error, _} ->
            false
        end
      end)

    {:ok, count}
  end

  @doc """
  Atomically increments and returns the next ticket number for a workspace.
  """
  @spec next_ticket_number!(Workspace.t()) :: integer()
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

  @doc """
  Derives a ticket prefix from a workspace name.

  Takes the first three alphabetic characters and upcases them.
  Falls back to `"AG"` if no letters are found.
  """
  @spec prefix_for_name(String.t()) :: String.t()
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
