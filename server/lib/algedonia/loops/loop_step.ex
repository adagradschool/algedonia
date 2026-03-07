defmodule Algedonia.Loops.LoopStep do
  @moduledoc """
  Schema for a loop step — a single maker or checker execution within a loop.
  Replaces the in-memory TaskLoopHistory with DB-persisted step tracking.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Algedonia.Loops.Loop

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "loop_steps" do
    field :role, :string
    field :attempt, :integer
    field :status, :string
    field :session_id, :string
    field :exit_code, :integer
    field :verdict, :string
    field :feedback, :string
    field :feedback_path, :string
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :loop, Algedonia.Loops.Loop
  end

  @type t :: %__MODULE__{
          id: Algedonia.Types.id(),
          loop_id: Algedonia.Types.id(),
          loop: Loop.t() | Ecto.Association.NotLoaded.t(),
          role: String.t(),
          attempt: integer(),
          status: String.t(),
          session_id: String.t() | nil,
          exit_code: integer() | nil,
          verdict: String.t() | nil,
          feedback: String.t() | nil,
          feedback_path: String.t() | nil,
          error: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  @required [:loop_id, :role, :attempt, :status, :started_at]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :loop_id,
      :role,
      :attempt,
      :status,
      :session_id,
      :exit_code,
      :verdict,
      :feedback,
      :feedback_path,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required(@required)
  end
end
