defmodule AlgedoniaWeb.TicketLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Algedonia.Factory

  describe "Index" do
    test "renders ticket board", %{conn: conn} do
      ticket = insert_ticket!(%{title: "Board ticket"})
      {:ok, _view, html} = live(conn, ~p"/tickets")
      assert html =~ "Active issues"
      assert html =~ "Board ticket"
      assert html =~ String.slice(ticket.id, 0, 8)
    end

    test "renders ticket list view", %{conn: conn} do
      insert_ticket!(%{title: "List ticket"})
      {:ok, _view, html} = live(conn, ~p"/tickets?view=list")
      assert html =~ "List ticket"
    end

    test "toggles between board and list views", %{conn: conn} do
      insert_ticket!(%{title: "Toggle ticket"})
      {:ok, view, _html} = live(conn, ~p"/tickets")

      assert view
             |> element(~s{button[phx-value-view="list"]})
             |> render_click() =~ "Toggle ticket"
    end

    test "creates a ticket via modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tickets")

      assert view |> element(~s{a[href="/tickets/new"]}) |> render_click() =~
               "Title"

      view
      |> form("#ticket-form", ticket: %{title: "Created ticket", type: :bug, priority: 2})
      |> render_submit()

      assert_patch(view, ~p"/tickets")
      assert render(view) =~ "Created ticket"
    end

    test "edits a ticket", %{conn: conn} do
      ticket = insert_ticket!(%{title: "Original title"})
      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket}/edit")

      view
      |> form("#ticket-form", ticket: %{title: "Edited title"})
      |> render_submit()

      assert_patch(view, ~p"/tickets")
      assert render(view) =~ "Edited title"
    end

    test "deletes a ticket", %{conn: conn} do
      ticket = insert_ticket!(%{title: "Doomed ticket"})
      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket}")

      view
      |> element(~s{button[phx-click="delete"]})
      |> render_click()

      assert_patch(view, ~p"/tickets")
      refute render(view) =~ "Doomed ticket"
    end

    test "opens detail panel", %{conn: conn} do
      ticket = insert_ticket!(%{title: "Detail ticket", description: "Detail desc"})
      {:ok, _view, html} = live(conn, ~p"/tickets/#{ticket}")

      assert html =~ "Detail ticket"
      assert html =~ "Detail desc"
    end

    test "filters by status", %{conn: conn} do
      insert_ticket!(%{title: "Backlog one", status: :backlog})
      insert_ticket!(%{title: "Progress one", status: :in_progress})

      {:ok, _view, html} = live(conn, ~p"/tickets?status=backlog")
      assert html =~ "Backlog one"
      refute html =~ "Progress one"
    end
  end

  describe "Comments" do
    test "ticket detail shows activity section", %{conn: conn} do
      ticket = insert_ticket!(%{title: "Commentable"})
      {:ok, _view, html} = live(conn, ~p"/tickets/#{ticket}")
      assert html =~ "Activity"
      assert html =~ "Leave a comment..."
    end

    test "user can post a comment and it appears", %{conn: conn} do
      ticket = insert_ticket!(%{title: "Has comments"})
      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket}")

      view
      |> form(~s{form[phx-submit="submit_comment"]},
        comment: %{body: "My first comment"}
      )
      |> render_submit()

      assert render(view) =~ "My first comment"
    end

    test "user can reply to a comment", %{conn: conn} do
      ticket = insert_ticket!()

      {:ok, parent} =
        Algedonia.Tickets.create_comment(%{ticket_id: ticket.id, author: "bob", body: "Parent"})

      {:ok, view, html} = live(conn, ~p"/tickets/#{ticket}")
      assert html =~ "Parent"

      view
      |> element(~s{button[phx-click="start_reply"][phx-value-comment-id="#{parent.id}"]})
      |> render_click()

      view
      |> form(~s{form[phx-submit="submit_reply"]},
        comment: %{body: "A reply"}
      )
      |> render_submit()

      assert render(view) =~ "A reply"
    end

    test "comment appears in real time via PubSub", %{conn: conn} do
      ticket = insert_ticket!()
      {:ok, view, _html} = live(conn, ~p"/tickets/#{ticket}")

      Algedonia.Tickets.create_comment(%{
        ticket_id: ticket.id,
        author: "external",
        body: "PubSub comment"
      })

      assert render(view) =~ "PubSub comment"
    end
  end
end
