defmodule Algedonia.Tickets.QueueEntry do
  @moduledoc """
  Persisted queue state for tickets.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "queue_entries" do
    field :workspace_id, :binary_id
    field :ticket_id, :binary_id
    field :status, :string, default: "queued"
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Algedonia.Types.id(),
          workspace_id: Algedonia.Types.id(),
          ticket_id: Algedonia.Types.id() | nil,
          status: String.t(),
          position: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(queue_entry, attrs) do
    queue_entry
    |> cast(attrs, [:workspace_id, :ticket_id, :status, :position])
    |> validate_required([:workspace_id, :status, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:workspace_id, :ticket_id],
      name: :idx_queue_entries_workspace_id_ticket_id_unique
    )
  end
end
