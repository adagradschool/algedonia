defmodule Algedonia.InlineReviews do
  @moduledoc """
  Context for inline review comments on diffs within loops.
  """
  import Ecto.Query

  alias Algedonia.InlineReviews.InlineReview
  alias Algedonia.Repo

  @doc """
  Creates an inline review comment.
  """
  @spec create(map()) :: {:ok, InlineReview.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %InlineReview{}
    |> InlineReview.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists all inline reviews for a loop, ordered by file path and line number.
  """
  @spec list_by_loop(binary()) :: [InlineReview.t()]
  def list_by_loop(loop_id) do
    from(r in InlineReview,
      where: r.loop_id == ^loop_id,
      order_by: [asc: r.file_path, asc: r.line_number, asc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists pending inline reviews for a loop.
  """
  @spec list_pending_by_loop(binary()) :: [InlineReview.t()]
  def list_pending_by_loop(loop_id) do
    from(r in InlineReview,
      where: r.loop_id == ^loop_id and r.status == :pending,
      order_by: [asc: r.file_path, asc: r.line_number, asc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Updates the status of an inline review.
  """
  @spec update_status(InlineReview.t(), atom()) ::
          {:ok, InlineReview.t()} | {:error, Ecto.Changeset.t()}
  def update_status(%InlineReview{} = review, status) do
    review
    |> InlineReview.changeset(%{status: status})
    |> Repo.update()
  end

  @doc """
  Serializes pending inline reviews for inclusion in the maker prompt.

  Returns nil if no reviews, or a formatted string with file:line, diff hunk context,
  and attributed comment body.
  """
  @spec serialize_for_prompt([InlineReview.t()]) :: String.t() | nil
  def serialize_for_prompt([]), do: nil

  def serialize_for_prompt(reviews) do
    blocks =
      Enum.map_join(reviews, "\n\n", fn review ->
        hunk_lines =
          review.diff_hunk
          |> String.split("\n")
          |> Enum.map_join("\n", &"> #{&1}")

        """
        --- #{review.file_path}:#{review.line_number}
        #{hunk_lines}
        Comment by #{review.author}: "#{review.body}"\
        """
      end)

    "Inline review comments:\n\n#{blocks}"
  end
end
