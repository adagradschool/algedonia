defmodule Algedonia.Factory do
  @moduledoc """
  Test factory for building and inserting test data.
  """
  alias Algedonia.Daemons.DaemonRegistration
  alias Algedonia.Dags.Dag
  alias Algedonia.Loops.{Loop, LoopDependency}
  alias Algedonia.Repo
  alias Algedonia.Tickets.Ticket

  @doc """
  Returns a map of valid ticket attributes, merged with overrides.
  """
  def ticket_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Test ticket #{System.unique_integer([:positive])}",
        type: :feature,
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
    %Ticket{}
    |> Ticket.changeset(ticket_attrs(overrides))
    |> Repo.insert!()
  end

  @doc """
  Returns a map of valid daemon registration attributes, merged with overrides.
  """
  def daemon_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "daemon-#{System.unique_integer([:positive])}",
        display_name: "Test Daemon",
        status: :online,
        capacity: 3,
        running_loops: 0,
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
  Returns a map of valid DAG attributes, merged with overrides.
  """
  def dag_attrs(overrides \\ %{}) do
    Map.merge(%{status: :running}, overrides)
  end

  @doc """
  Inserts a DAG into the database with optional attribute overrides.
  Requires `:ticket_id` in overrides (or creates a ticket).
  """
  def insert_dag!(overrides \\ %{}) do
    overrides =
      if Map.has_key?(overrides, :ticket_id) do
        overrides
      else
        ticket = insert_ticket!()
        Map.put(overrides, :ticket_id, ticket.id)
      end

    %Dag{}
    |> Dag.changeset(dag_attrs(overrides))
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
        max_attempts: 3
      },
      overrides
    )
  end

  @doc """
  Inserts a loop into the database with optional attribute overrides.
  Requires `:dag_id` in overrides (or creates a DAG).
  """
  def insert_loop!(overrides \\ %{}) do
    overrides =
      if Map.has_key?(overrides, :dag_id) do
        overrides
      else
        dag = insert_dag!()
        Map.put(overrides, :dag_id, dag.id)
      end

    %Loop{}
    |> Loop.changeset(loop_attrs(overrides))
    |> Repo.insert!()
  end

  @doc """
  Inserts a loop dependency.
  """
  def insert_loop_dependency!(upstream_loop_id, downstream_loop_id) do
    %LoopDependency{}
    |> LoopDependency.changeset(%{
      upstream_loop_id: upstream_loop_id,
      downstream_loop_id: downstream_loop_id
    })
    |> Repo.insert!()
  end
end
