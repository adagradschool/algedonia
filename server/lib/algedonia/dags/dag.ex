defmodule Algedonia.Dags.Dag do
  @moduledoc """
  Schema for a DAG — a directed acyclic graph of maker-checker loops for a ticket.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "dags" do
    field :status, Ecto.Enum, values: [:running, :completed, :failed], default: :running

    belongs_to :ticket, Algedonia.Tickets.Ticket
    has_many :loops, Algedonia.Loops.Loop

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(dag, attrs) do
    dag
    |> cast(attrs, [:status, :ticket_id])
    |> validate_required([:ticket_id])
    |> unique_constraint(:ticket_id)
  end
end
