defmodule AlgedoniaWeb.Api.CommentControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Algedonia.Factory

  setup %{workspace: workspace, user: user} do
    token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    ticket = insert_ticket!(%{workspace_id: workspace.id})

    {:ok, conn: conn, workspace: workspace, ticket: ticket}
  end

  describe "GET /api/w/:workspace/tickets/:ticket_id/comments" do
    test "lists comments", %{conn: conn, workspace: workspace, ticket: ticket} do
      {:ok, _} =
        Algedonia.Tickets.create_comment(%{
          "ticket_id" => ticket.id,
          "author" => "alice",
          "body" => "hello"
        })

      conn = get(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.number}/comments")
      %{"comments" => comments} = json_response(conn, 200)

      assert length(comments) == 1
      assert hd(comments)["author"] == "alice"
    end
  end

  describe "POST /api/w/:workspace/tickets/:ticket_id/comments" do
    test "creates a comment", %{conn: conn, workspace: workspace, ticket: ticket} do
      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.number}/comments", %{
          "comment" => %{"author" => "bob", "body" => "nice work"}
        })

      %{"comment" => comment} = json_response(conn, 201)
      assert comment["author"] == "bob"
      assert comment["body"] == "nice work"
    end

    test "returns error for missing fields", %{conn: conn, workspace: workspace, ticket: ticket} do
      conn =
        post(conn, "/api/w/#{workspace.slug}/tickets/#{ticket.number}/comments", %{
          "comment" => %{}
        })

      assert %{"errors" => %{"author" => ["Can't be blank"], "body" => ["Can't be blank"]}} =
               json_response(conn, 422)
    end
  end

  describe "PATCH /api/w/:workspace/tickets/:ticket_id/comments/:id" do
    test "updates a comment", %{conn: conn, workspace: workspace, ticket: ticket} do
      {:ok, comment} =
        Algedonia.Tickets.create_comment(%{
          "ticket_id" => ticket.id,
          "author" => "alice",
          "body" => "original"
        })

      conn =
        patch(
          conn,
          "/api/w/#{workspace.slug}/tickets/#{ticket.number}/comments/#{comment.id}",
          %{"comment" => %{"body" => "updated"}}
        )

      %{"comment" => updated} = json_response(conn, 200)
      assert updated["body"] == "updated"
      assert updated["id"] == comment.id
    end

    test "returns 404 for nonexistent comment", %{
      conn: conn,
      workspace: workspace,
      ticket: ticket
    } do
      conn =
        patch(
          conn,
          "/api/w/#{workspace.slug}/tickets/#{ticket.number}/comments/#{Ecto.UUID.generate()}",
          %{"comment" => %{"body" => "updated"}}
        )

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/w/:workspace/tickets/:ticket_id/comments/:id" do
    test "deletes a comment", %{conn: conn, workspace: workspace, ticket: ticket} do
      {:ok, comment} =
        Algedonia.Tickets.create_comment(%{
          "ticket_id" => ticket.id,
          "author" => "alice",
          "body" => "to delete"
        })

      conn =
        delete(
          conn,
          "/api/w/#{workspace.slug}/tickets/#{ticket.number}/comments/#{comment.id}"
        )

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns 404 for nonexistent comment", %{
      conn: conn,
      workspace: workspace,
      ticket: ticket
    } do
      conn =
        delete(
          conn,
          "/api/w/#{workspace.slug}/tickets/#{ticket.number}/comments/#{Ecto.UUID.generate()}"
        )

      assert json_response(conn, 404)
    end
  end
end
