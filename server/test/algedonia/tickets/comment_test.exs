defmodule Algedonia.Tickets.CommentTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Tickets
  alias Algedonia.Tickets.Comment
  import Algedonia.Factory

  describe "create_comment/1" do
    test "creates a top-level comment" do
      ticket = insert_ticket!()
      attrs = %{ticket_id: ticket.id, author: "alice", body: "Looks good!"}
      assert {:ok, comment} = Tickets.create_comment(attrs)
      assert comment.author == "alice"
      assert comment.body == "Looks good!"
      assert comment.ticket_id == ticket.id
      assert is_nil(comment.parent_id)
    end

    test "creates a reply to an existing comment" do
      ticket = insert_ticket!()
      {:ok, parent} = Tickets.create_comment(%{ticket_id: ticket.id, author: "alice", body: "Q"})
      attrs = %{ticket_id: ticket.id, author: "bob", body: "A", parent_id: parent.id}
      assert {:ok, reply} = Tickets.create_comment(attrs)
      assert reply.parent_id == parent.id
    end

    test "returns error without required fields" do
      assert {:error, %Ecto.Changeset{}} = Tickets.create_comment(%{})
    end

    test "returns error without body" do
      ticket = insert_ticket!()
      assert {:error, changeset} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a"})
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_comments/1" do
    test "returns comments for a ticket in order" do
      ticket = insert_ticket!()
      {:ok, c1} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "first"})
      {:ok, c2} = Tickets.create_comment(%{ticket_id: ticket.id, author: "b", body: "second"})

      comments = Tickets.list_comments(ticket.id)
      ids = Enum.map(comments, & &1.id)
      assert ids == [c1.id, c2.id]
    end

    test "returns only top-level comments with replies preloaded" do
      ticket = insert_ticket!()
      {:ok, parent} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "top"})

      {:ok, reply} =
        Tickets.create_comment(%{
          ticket_id: ticket.id,
          author: "b",
          body: "reply",
          parent_id: parent.id
        })

      comments = Tickets.list_comments(ticket.id)
      assert length(comments) == 1
      assert hd(comments).id == parent.id
      assert [r] = hd(comments).replies
      assert r.id == reply.id
    end

    test "returns empty list for ticket with no comments" do
      ticket = insert_ticket!()
      assert Tickets.list_comments(ticket.id) == []
    end
  end

  describe "update_comment/2" do
    test "updates the body of a comment" do
      ticket = insert_ticket!()
      {:ok, comment} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "old"})
      assert {:ok, updated} = Tickets.update_comment(comment, %{body: "new"})
      assert updated.body == "new"
      assert updated.id == comment.id
    end

    test "returns error for invalid update" do
      ticket = insert_ticket!()
      {:ok, comment} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "ok"})
      assert {:error, %Ecto.Changeset{}} = Tickets.update_comment(comment, %{body: nil})
    end
  end

  describe "delete_comment/1" do
    test "deletes a comment" do
      ticket = insert_ticket!()
      {:ok, comment} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "bye"})
      assert {:ok, _} = Tickets.delete_comment(comment)
      assert Tickets.list_comments(ticket.id) == []
    end

    test "deletes a comment and its replies" do
      ticket = insert_ticket!()
      {:ok, parent} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "top"})

      {:ok, _reply} =
        Tickets.create_comment(%{
          ticket_id: ticket.id,
          author: "b",
          body: "child",
          parent_id: parent.id
        })

      assert {:ok, _} = Tickets.delete_comment(parent)
      assert Tickets.list_comments(ticket.id) == []
    end
  end

  describe "PubSub" do
    test "broadcasts comment_created on new comment" do
      ticket = insert_ticket!()
      Tickets.subscribe_comments(ticket.workspace_id, ticket.id)

      {:ok, comment} =
        Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "hi"})

      assert_receive {:comment_created, ^comment}
    end

    test "broadcasts comment_updated on edit" do
      ticket = insert_ticket!()
      Tickets.subscribe_comments(ticket.workspace_id, ticket.id)
      {:ok, comment} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "v1"})
      assert_receive {:comment_created, _}

      {:ok, updated} = Tickets.update_comment(comment, %{body: "v2"})
      assert_receive {:comment_updated, ^updated}
    end

    test "broadcasts comment_deleted on delete" do
      ticket = insert_ticket!()
      Tickets.subscribe_comments(ticket.workspace_id, ticket.id)
      {:ok, comment} = Tickets.create_comment(%{ticket_id: ticket.id, author: "a", body: "bye"})
      assert_receive {:comment_created, _}

      {:ok, deleted} = Tickets.delete_comment(comment)
      assert_receive {:comment_deleted, ^deleted}
    end
  end

  describe "change_comment/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} = Tickets.change_comment(%Comment{})
    end
  end
end
