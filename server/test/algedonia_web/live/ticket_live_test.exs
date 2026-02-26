defmodule AlgedoniaWeb.TicketLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias Algedonia.{Dags, Tickets}

  import Phoenix.LiveViewTest
  import Algedonia.Factory

  describe "Index" do
    test "renders ticket board", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{title: "Board ticket", workspace_id: workspace.id})
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets")
      assert html =~ "Active issues"
      assert html =~ "Board ticket"
      assert html =~ "#{workspace.prefix}-#{ticket.number}"
    end

    test "renders ticket list view", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{title: "List ticket", workspace_id: workspace.id})
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets?view=list")
      assert html =~ "List ticket"
    end

    test "toggles between board and list views", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{title: "Toggle ticket", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      assert view
             |> element(~s{button[phx-value-view="list"]})
             |> render_click() =~ "Toggle ticket"
    end

    test "creates a ticket via modal", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      modal_html = view |> element("#new-issue-button") |> render_click()
      assert modal_html =~ "Title"
      refute modal_html =~ "Keep it tight and actionable."

      view
      |> form("#ticket-form", ticket: %{title: "Created ticket", type: :bug, priority: 2})
      |> render_submit()

      assert_patch(view, ~p"/w/#{workspace.slug}/tickets")
      assert render(view) =~ "Created ticket"
    end

    test "shows capitalized form errors", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      view |> element("#new-issue-button") |> render_click()

      html =
        view
        |> form("#ticket-form", ticket: %{title: "", type: :bug, priority: 2})
        |> render_change()

      assert html =~ ~r/Can(?:'|&#39;|&apos;)t be blank/
    end

    test "edits a ticket", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{title: "Original title", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}/edit")

      view
      |> form("#ticket-form", ticket: %{title: "Edited title"})
      |> render_submit()

      assert_patch(view, ~p"/w/#{workspace.slug}/tickets")
      assert render(view) =~ "Edited title"
    end

    test "deletes a ticket", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{title: "Doomed ticket", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element(~s{button[phx-click="confirm_delete"]})
      |> render_click()

      view
      |> element(~s{button[phx-click="confirm_delete_now"]})
      |> render_click()

      assert_patch(view, ~p"/w/#{workspace.slug}/tickets")
      refute render(view) =~ "Doomed ticket"
    end

    test "opens detail panel", %{conn: conn, workspace: workspace} do
      ticket =
        insert_ticket!(%{
          title: "Detail ticket",
          description: "Detail desc",
          workspace_id: workspace.id
        })

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert html =~ "Detail ticket"
      assert html =~ "Detail desc"
    end

    test "filters by status", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{title: "Backlog one", status: :backlog, workspace_id: workspace.id})
      insert_ticket!(%{title: "Progress one", status: :in_progress, workspace_id: workspace.id})

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets?status=backlog")
      assert html =~ "Backlog one"
      refute html =~ "Progress one"
    end

    test "start work from list creates loop and navigates to loop screen", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{title: "Loop me", status: :backlog, workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets?view=list")

      view
      |> element(~s{button[phx-click="start_work"][phx-value-id="#{ticket.id}"]})
      |> render_click()

      dag = Dags.get_dag_by_ticket(ticket.id)
      loop = List.first(dag.loops)

      assert_redirect(
        view,
        ~p"/w/#{workspace.slug}/loops/#{loop.id}?#{%{autostart: 1, agent_type: "claude_code"}}"
      )

      assert Tickets.get_ticket!(ticket.id).status == :in_progress
    end

    test "start work with codex ticket navigates with codex agent_type", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{
          title: "Loop me with Codex",
          status: :backlog,
          coding_agent: :codex,
          workspace_id: workspace.id
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets?view=list")

      view
      |> element(~s{button[phx-click="start_work"][phx-value-id="#{ticket.id}"]})
      |> render_click()

      dag = Dags.get_dag_by_ticket(ticket.id)
      loop = List.first(dag.loops)

      assert_redirect(
        view,
        ~p"/w/#{workspace.slug}/loops/#{loop.id}?#{%{autostart: 1, agent_type: "codex"}}"
      )

      assert Tickets.get_ticket!(ticket.id).status == :in_progress
    end
  end

  describe "Comments" do
    test "ticket detail shows activity section", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{title: "Commentable", workspace_id: workspace.id})
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert html =~ "Activity"
      assert html =~ "Leave a comment..."
    end

    test "user can post a comment and it appears", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{title: "Has comments", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> form(~s{form[phx-submit="submit_comment"]},
        comment: %{body: "My first comment"}
      )
      |> render_submit()

      assert render(view) =~ "My first comment"
    end

    test "user can reply to a comment", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})

      {:ok, parent} =
        Algedonia.Tickets.create_comment(%{ticket_id: ticket.id, author: "bob", body: "Parent"})

      {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
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

    test "user can edit a comment", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})

      {:ok, comment} =
        Algedonia.Tickets.create_comment(%{ticket_id: ticket.id, author: "You", body: "Original"})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert render(view) =~ "Original"

      view
      |> element(~s{button[phx-click="edit_comment"][phx-value-id="#{comment.id}"]})
      |> render_click()

      assert render(view) =~ "edit_#{comment.id}"

      view
      |> form(~s{form[phx-submit="update_comment"]}, comment: %{body: "Edited"})
      |> render_submit()

      assert render(view) =~ "Edited"
      refute render(view) =~ "edit_#{comment.id}"
    end

    test "user can cancel editing a comment", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})

      {:ok, comment} =
        Algedonia.Tickets.create_comment(%{ticket_id: ticket.id, author: "You", body: "Keep me"})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element(~s{button[phx-click="edit_comment"][phx-value-id="#{comment.id}"]})
      |> render_click()

      view
      |> element(~s{button[phx-click="cancel_edit"]})
      |> render_click()

      refute render(view) =~ "edit_#{comment.id}"
      assert render(view) =~ "Keep me"
    end

    test "user can delete a comment", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})

      Algedonia.Tickets.create_comment(%{ticket_id: ticket.id, author: "bob", body: "Delete me"})

      {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert html =~ "Delete me"

      view
      |> element(~s{button[phx-click="delete_comment"]})
      |> render_click()

      refute render(view) =~ "Delete me"
    end

    test "comment appears in real time via PubSub", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      Algedonia.Tickets.create_comment(%{
        ticket_id: ticket.id,
        author: "external",
        body: "PubSub comment"
      })

      assert render(view) =~ "PubSub comment"
    end
  end
end
