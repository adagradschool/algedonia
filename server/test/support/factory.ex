defmodule Algedonia.Factory do
  @moduledoc """
  Test factory for building and inserting test data.
  """
  alias Algedonia.Accounts.User
  alias Algedonia.Daemons.DaemonRegistration
  alias Algedonia.Loops.Loop
  alias Algedonia.Repo
  alias Algedonia.Tickets.Ticket
  alias Algedonia.Workspaces.{Workspace, WorkspaceMembership}

  @doc """
  Returns a map of valid ticket attributes, merged with overrides.
  """
  def ticket_attrs(overrides \\ %{}) do
    overrides =
      if Map.has_key?(overrides, :workspace_id) do
        overrides
      else
        workspace = default_workspace!()
        Map.put(overrides, :workspace_id, workspace.id)
      end

    Map.merge(
      %{
        title: "Test ticket #{System.unique_integer([:positive])}",
        number: System.unique_integer([:positive]),
        type: :feature,
        coding_agent: :claude_code,
        priority: 3,
        status: :backlog,
        description: "A test ticket description",
        assignee: "alice"
      },
      overrides
    )
  end

  @doc """
  Inserts a ticket into the database with optional attribute overrides.
  """
  def insert_ticket!(overrides \\ %{}) do
    {workspace, overrides} =
      if Map.has_key?(overrides, :workspace_id) do
        workspace = Repo.get!(Workspace, overrides.workspace_id)
        {workspace, overrides}
      else
        workspace = default_workspace!()
        {workspace, Map.put(overrides, :workspace_id, workspace.id)}
      end

    overrides =
      if Map.has_key?(overrides, :number) do
        overrides
      else
        Map.put(overrides, :number, Algedonia.Workspaces.next_ticket_number!(workspace))
      end

    %Ticket{}
    |> Ticket.changeset(ticket_attrs(overrides))
    |> Repo.insert!()
  end

  @doc """
  Returns a default workspace for the current test process.
  """
  def default_workspace! do
    case Process.get(:default_workspace) do
      %Workspace{} = workspace ->
        workspace

      _ ->
        workspace = insert_workspace!(%{slug: "algedonia", name: "Algedonia"})
        Process.put(:default_workspace, workspace)
        workspace
    end
  end

  def workspace_attrs(overrides \\ %{}) do
    name = Map.get(overrides, :name, "Algedonia")

    Map.merge(
      %{
        name: name,
        slug: "algedonia-#{System.unique_integer([:positive])}",
        prefix: Algedonia.Workspaces.prefix_for_name(name),
        next_ticket_number: 1
      },
      overrides
    )
  end

  def insert_workspace!(overrides \\ %{}) do
    %Workspace{}
    |> Workspace.changeset(workspace_attrs(overrides))
    |> Repo.insert!()
  end

  def user_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "user-#{System.unique_integer([:positive])}",
        email: nil
      },
      overrides
    )
  end

  def insert_user!(overrides \\ %{}) do
    if Map.has_key?(overrides, :github_username) || Map.has_key?(overrides, :github_id) do
      attrs =
        overrides
        |> Map.put_new(:github_id, System.unique_integer([:positive]))
        |> Map.put_new(:name, "user-#{System.unique_integer([:positive])}")

      %User{}
      |> User.github_changeset(attrs)
      |> Repo.insert!()
    else
      %User{}
      |> User.changeset(user_attrs(overrides))
      |> Repo.insert!()
    end
  end

  def insert_membership!(workspace, user, overrides \\ %{}) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(
      Map.merge(%{workspace_id: workspace.id, user_id: user.id, role: "member"}, overrides)
    )
    |> Repo.insert!()
  end

  @doc """
  Returns a map of valid daemon registration attributes, merged with overrides.
  """
  def daemon_attrs(overrides \\ %{}) do
    overrides =
      if Map.has_key?(overrides, :user_id) do
        overrides
      else
        user = insert_user!()
        Map.put(overrides, :user_id, user.id)
      end

    Map.merge(
      %{
        name: "daemon-#{System.unique_integer([:positive])}",
        display_name: "Test Daemon",
        status: :online,
        capacity: 3,
        running_loops: 0,
        available_agents: [],
        bare_repos: [],
        last_heartbeat_at: DateTime.utc_now(),
        connected_at: DateTime.utc_now()
      },
      overrides
    )
  end

  @doc """
  Inserts a daemon registration into the database with optional attribute overrides.
  """
  def insert_daemon!(overrides \\ %{}) do
    %DaemonRegistration{}
    |> DaemonRegistration.changeset(daemon_attrs(overrides))
    |> Repo.insert!()
  end

  @doc """
  Returns a map of valid loop attributes, merged with overrides.
  """
  def loop_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Loop #{System.unique_integer([:positive])}",
        status: :pending,
        role: :task,
        max_attempts: 10
      },
      overrides
    )
  end

  @doc """
  Inserts a loop into the database with optional attribute overrides.
  Requires `:ticket_id` in overrides (or creates a ticket).
  """
  def insert_loop!(overrides \\ %{}) do
    overrides =
      if Map.has_key?(overrides, :ticket_id) do
        overrides
      else
        ticket = insert_ticket!()
        Map.put(overrides, :ticket_id, ticket.id)
      end

    overrides =
      if Map.has_key?(overrides, :workspace_id) do
        overrides
      else
        ticket = Repo.get!(Ticket, overrides.ticket_id)
        Map.put(overrides, :workspace_id, ticket.workspace_id)
      end

    %Loop{}
    |> Loop.changeset(loop_attrs(overrides))
    |> Repo.insert!()
  end
end
