defmodule Algedonia.Tickets.Ticket do
  @moduledoc """
  Schema for a ticket — the primary unit of work in Algedonia.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tickets" do
    belongs_to :workspace, Algedonia.Workspaces.Workspace, type: :id
    field :title, :string
    field :description, :string
    field :number, :integer

    field :status, Ecto.Enum,
      values: [:backlog, :decomposing, :halted, :in_progress, :completed, :archived],
      default: :backlog

    field :type, Ecto.Enum, values: [:feature, :bug, :chore, :spike]
    field :priority, :integer, default: 3
    field :assignee, :string
    field :acceptance_criteria, :string
    field :rubric, :string

    has_many :comments, Algedonia.Tickets.Comment

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Returns a changeset for creating or updating a ticket.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :workspace_id,
      :number,
      :title,
      :description,
      :status,
      :type,
      :priority,
      :assignee,
      :acceptance_criteria,
      :rubric
    ])
    |> validate_required([:workspace_id, :title, :type, :priority])
    |> validate_inclusion(:priority, 1..5)
  end
end
