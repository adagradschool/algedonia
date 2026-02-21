defmodule Algedonia.Factory do
  @moduledoc """
  Test factory for building and inserting test data.
  """
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
end
