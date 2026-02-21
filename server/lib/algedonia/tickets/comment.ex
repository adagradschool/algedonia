defmodule Algedonia.Tickets.Comment do
  @moduledoc """
  Schema for a comment on a ticket — supports threading via parent_id.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Algedonia.Tickets.Ticket

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "comments" do
    field :author, :string
    field :body, :string

    belongs_to :ticket, Ticket
    belongs_to :parent, __MODULE__
    has_many :replies, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:author, :body, :ticket_id, :parent_id])
    |> validate_required([:author, :body, :ticket_id])
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:parent_id)
  end
end
