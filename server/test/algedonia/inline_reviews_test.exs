defmodule Algedonia.InlineReviewsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.InlineReviews
  alias Algedonia.InlineReviews.InlineReview
  import Algedonia.Factory

  defp review_attrs(loop, overrides \\ %{}) do
    Map.merge(
      %{
        loop_id: loop.id,
        author: "ada",
        file_path: "server/lib/app.ex",
        line_number: 42,
        diff_hunk: "+    new_code()",
        body: "Consider extracting this into a helper."
      },
      overrides
    )
  end

  describe "create/1" do
    test "creates an inline review with valid attrs" do
      loop = insert_loop!()
      attrs = review_attrs(loop)
      assert {:ok, %InlineReview{} = review} = InlineReviews.create(attrs)
      assert review.loop_id == loop.id
      assert review.author == "ada"
      assert review.file_path == "server/lib/app.ex"
      assert review.line_number == 42
      assert review.diff_hunk == "+    new_code()"
      assert review.body == "Consider extracting this into a helper."
      assert review.status == :pending
    end

    test "returns error changeset with missing required fields" do
      assert {:error, %Ecto.Changeset{}} = InlineReviews.create(%{})
    end

    test "returns error changeset with invalid loop_id" do
      attrs = %{
        loop_id: Ecto.UUID.generate(),
        author: "ada",
        file_path: "test.ex",
        line_number: 1,
        diff_hunk: "+ code",
        body: "comment"
      }

      assert {:error, %Ecto.Changeset{}} = InlineReviews.create(attrs)
    end
  end

  describe "list_by_loop/1" do
    test "returns reviews for the given loop, ordered by file and line" do
      loop = insert_loop!()

      {:ok, r1} = InlineReviews.create(review_attrs(loop, %{file_path: "b.ex", line_number: 10}))
      {:ok, r2} = InlineReviews.create(review_attrs(loop, %{file_path: "a.ex", line_number: 5}))
      {:ok, r3} = InlineReviews.create(review_attrs(loop, %{file_path: "a.ex", line_number: 20}))

      reviews = InlineReviews.list_by_loop(loop.id)
      assert [first, second, third] = reviews
      assert first.id == r2.id
      assert second.id == r3.id
      assert third.id == r1.id
    end

    test "returns empty list for loop with no reviews" do
      loop = insert_loop!()
      assert InlineReviews.list_by_loop(loop.id) == []
    end

    test "does not return reviews from other loops" do
      loop1 = insert_loop!()
      loop2 = insert_loop!()
      {:ok, _} = InlineReviews.create(review_attrs(loop1))

      assert InlineReviews.list_by_loop(loop2.id) == []
    end
  end

  describe "list_pending_by_loop/1" do
    test "returns only pending reviews" do
      loop = insert_loop!()
      {:ok, r1} = InlineReviews.create(review_attrs(loop, %{line_number: 1}))
      {:ok, r2} = InlineReviews.create(review_attrs(loop, %{line_number: 2}))
      {:ok, _} = InlineReviews.update_status(r2, :resolved)

      pending = InlineReviews.list_pending_by_loop(loop.id)
      assert length(pending) == 1
      assert hd(pending).id == r1.id
    end
  end

  describe "update_status/2" do
    test "updates review status to addressed" do
      loop = insert_loop!()
      {:ok, review} = InlineReviews.create(review_attrs(loop))
      assert {:ok, updated} = InlineReviews.update_status(review, :addressed)
      assert updated.status == :addressed
    end

    test "updates review status to resolved" do
      loop = insert_loop!()
      {:ok, review} = InlineReviews.create(review_attrs(loop))
      assert {:ok, updated} = InlineReviews.update_status(review, :resolved)
      assert updated.status == :resolved
    end
  end

  describe "serialize_for_prompt/1" do
    test "returns nil for empty list" do
      assert InlineReviews.serialize_for_prompt([]) == nil
    end

    test "formats reviews with file, line, hunk, and attributed comment" do
      loop = insert_loop!()

      {:ok, review} =
        InlineReviews.create(
          review_attrs(loop, %{
            file_path: "lib/orchestrator.ex",
            line_number: 142,
            diff_hunk: "-    old_code()\n+    new_code()",
            body: "Add error handling here.",
            author: "ada"
          })
        )

      result = InlineReviews.serialize_for_prompt([review])
      assert result =~ "Inline review comments:"
      assert result =~ "--- lib/orchestrator.ex:142"
      assert result =~ "> -    old_code()"
      assert result =~ "> +    new_code()"
      assert result =~ ~s(Comment by ada: "Add error handling here.")
    end

    test "formats multiple reviews" do
      loop = insert_loop!()

      {:ok, r1} =
        InlineReviews.create(
          review_attrs(loop, %{file_path: "a.ex", line_number: 1, body: "First comment"})
        )

      {:ok, r2} =
        InlineReviews.create(
          review_attrs(loop, %{file_path: "b.ex", line_number: 2, body: "Second comment"})
        )

      result = InlineReviews.serialize_for_prompt([r1, r2])
      assert result =~ "--- a.ex:1"
      assert result =~ "--- b.ex:2"
      assert result =~ "First comment"
      assert result =~ "Second comment"
    end
  end
end
