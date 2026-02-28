defmodule Algedonia.InlineReviews.InlineReview do
  @moduledoc """
  Schema for an inline review comment attached to a specific line in a diff.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :addressed, :resolved]

  schema "inline_reviews" do
    field :author, :string
    field :file_path, :string
    field :line_number, :integer
    field :diff_hunk, :string
    field :body, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending

    belongs_to :loop, Algedonia.Loops.Loop

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @required [:loop_id, :author, :file_path, :line_number, :diff_hunk, :body]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(review, attrs) do
    review
    |> cast(attrs, @required ++ [:status])
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:loop_id)
  end
end
