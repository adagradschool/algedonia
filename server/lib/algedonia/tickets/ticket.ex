defmodule Algedonia.Tickets.Ticket do
  @moduledoc """
  Schema for a ticket — the primary unit of work in Algedonia.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tickets" do
    field :title, :string
    field :description, :string

    field :status, Ecto.Enum,
      values: [:backlog, :decomposing, :decomposition_failed, :in_progress, :completed, :archived],
      default: :backlog

    field :type, Ecto.Enum, values: [:feature, :bug, :chore, :spike]
    field :priority, :integer, default: 3
    field :assignee, :string
    field :acceptance_criteria, :string
    field :rubric, :string

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
      :title,
      :description,
      :status,
      :type,
      :priority,
      :assignee,
      :acceptance_criteria,
      :rubric
    ])
    |> validate_required([:title, :type, :priority])
    |> validate_inclusion(:priority, 1..5)
  end
end
