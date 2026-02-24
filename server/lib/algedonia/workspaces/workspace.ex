defmodule Algedonia.Workspaces.Workspace do
  @moduledoc """
  Workspace schema for multi-tenant scoping.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :prefix, :string
    field :next_ticket_number, :integer, default: 1

    has_many :tickets, Algedonia.Tickets.Ticket
    has_many :workspace_memberships, Algedonia.Workspaces.WorkspaceMembership

    timestamps(type: :utc_datetime)
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :prefix, :next_ticket_number])
    |> validate_required([:name, :slug, :prefix])
    |> unique_constraint(:slug)
  end
end
