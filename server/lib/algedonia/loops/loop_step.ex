defmodule Algedonia.Loops.LoopStep do
  @moduledoc """
  Schema for a loop step — a single maker or checker execution within a loop.
  Replaces the in-memory TaskLoopHistory with DB-persisted step tracking.
  """
  use Ecto.Schema
  import Ecto.Changeset

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

  @type t :: %__MODULE__{}

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
