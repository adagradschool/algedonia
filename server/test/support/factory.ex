defmodule Algedonia.Factory do
  @moduledoc """
  Test factory for building and inserting test data.
  """
  alias Algedonia.Daemons.DaemonRegistration
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
end
