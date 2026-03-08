defmodule AlgedoniaWeb.TicketLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias Algedonia.{Loops, Tickets}
  alias Algedonia.PubSub.Topics
  alias AlgedoniaWeb.TicketLive.TicketFormComponent

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

    test "creates workspace from switcher modal and redirects to new workspace tickets", %{
      conn: conn,
      workspace: workspace
    } do
      insert_ticket!(%{title: "Old scope ticket", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      view
      |> element("#workspace-switcher-dropdown button", "New workspace")
      |> render_click()

      name = "Switcher Workspace #{System.unique_integer([:positive])}"
      slug = AlgedoniaWeb.Helpers.slugify(name)

      view
      |> form("#new-workspace-modal form", workspace: %{name: name})
      |> render_submit()

      assert_redirect(view, "/w/#{slug}/tickets")

      {:ok, redirected_view, redirected_html} = live(conn, ~p"/w/#{slug}/tickets")

      assert has_element?(
               redirected_view,
               "#global-command-palette[data-tickets-path='/w/#{slug}/tickets']"
             )

      refute redirected_html =~ "Old scope ticket"
    end

    test "workspace create failure keeps modal open and shows inline validation errors", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      view
      |> element("#workspace-switcher-dropdown button", "New workspace")
      |> render_click()

      html =
        view
        |> form("#new-workspace-modal form", workspace: %{name: "Algedonia"})
        |> render_submit()

      assert has_element?(view, "#new-workspace-modal")
      assert html =~ "Workspace name"
      assert html =~ ~r/has already been taken/i
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

    test "duplicates a ticket from detail settings", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{title: "Copy me", workspace_id: workspace.id, status: :backlog})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element("#ticket-duplicate-action")
      |> render_click()

      assert Enum.any?(
               Tickets.list_tickets(workspace_id: workspace.id),
               &(&1.title == "Copy me (Copy)")
             )
    end

    test "opens delete flow from detail settings", %{conn: conn, workspace: workspace} do
      ticket =
        insert_ticket!(%{title: "Delete from menu", workspace_id: workspace.id, status: :backlog})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element("#ticket-delete-action")
      |> render_click()

      html = render(view)
      assert html =~ "Delete issue?"
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

    test "detail markdown fields use tiptap editors", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{title: "TipTap detail", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert has_element?(view, "#ticket-description-field-editor[phx-hook='MarkdownEditor']")

      assert has_element?(
               view,
               "#ticket-acceptance-criteria-field-editor[phx-hook='MarkdownEditor']"
             )

      assert has_element?(view, "#ticket-rubric-field-editor[phx-hook='MarkdownEditor']")
    end

    test "ticket detail autosaves markdown fields via tiptap hook", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{
          title: "Autosave fields",
          workspace_id: workspace.id,
          description: "before",
          acceptance_criteria: "before",
          rubric: "before"
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      render_hook(view, "autosave_ticket_markdown", %{
        "field" => "description",
        "body" => "updated description\n\n- [x] shipped"
      })

      render_hook(view, "autosave_ticket_markdown", %{
        "field" => "acceptance_criteria",
        "body" => "| Criterion | Result |\n|---|---|\n| Title | Pass |"
      })

      render_hook(view, "autosave_ticket_markdown", %{
        "field" => "rubric",
        "body" => "- [ ] add tests"
      })

      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.description =~ "updated description"
      assert updated_ticket.acceptance_criteria =~ "| Criterion | Result |"
      assert updated_ticket.rubric =~ "- [ ] add tests"
    end

    test "sidebar coding_agent field persists after change", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{
          title: "Sidebar persist",
          workspace_id: workspace.id,
          coding_agent: :codex
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> form("#ticket-detail-form", ticket: %{coding_agent: "claude_code"})
      |> render_change()

      updated_ticket = Tickets.get_ticket!(ticket.id)
      assert updated_ticket.coding_agent == :claude_code
    end

    test "filters by status", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{title: "Backlog one", status: :backlog, workspace_id: workspace.id})
      insert_ticket!(%{title: "Progress one", status: :in_progress, workspace_id: workspace.id})

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets?status=backlog")
      assert html =~ "Backlog one"
      refute html =~ "Progress one"
    end

    test "filters by search query", %{conn: conn, workspace: workspace} do
      insert_ticket!(%{title: "Alpha migration", status: :backlog, workspace_id: workspace.id})
      insert_ticket!(%{title: "Beta cleanup", status: :backlog, workspace_id: workspace.id})

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets?q=alpha")
      assert html =~ "Alpha migration"
      refute html =~ "Beta cleanup"
    end

    test "plan from list moves ticket to planning and opens planning session", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{title: "Plan me", status: :backlog, workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets?view=list")

      view
      |> element(~s{button[phx-click="plan_ticket"][phx-value-id="#{ticket.id}"]})
      |> render_click()

      planning_loop = Loops.list_planning_loops_for_ticket(ticket.id) |> List.first()

      assert_redirect(
        view,
        ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(planning_loop.id, 0, 8)}?#{%{role: "planning", agent_type: "claude_code"}}"
      )

      assert Tickets.get_ticket!(ticket.id).status == :planning

      # A real planning loop must exist in the DB (not a ticket ID masquerading as a loop ref)
      assert [%{role: :planning}] = Loops.list_planning_loops_for_ticket(ticket.id)
    end

    test "start work from planning list creates loop and navigates to loop screen", %{
      conn: conn,
      workspace: workspace
    } do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{title: "Loop me", status: :planning, workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets?view=list")

      view
      |> element(~s{button[phx-click="start_work"][phx-value-id="#{ticket.id}"]})
      |> render_click()

      loop = Loops.list_task_loops_for_ticket(ticket.id) |> List.first()

      assert_redirect(
        view,
        ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(loop.id, 0, 8)}?#{%{agent_type: "claude_code"}}"
      )

      assert Tickets.get_ticket!(ticket.id).status == :in_progress
    end

    test "start work from planning list fails without daemon and stays planning", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{title: "Loop me", status: :planning, workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets?view=list")

      html =
        view
        |> element(~s{button[phx-click="start_work"][phx-value-id="#{ticket.id}"]})
        |> render_click()

      assert html =~ "No online daemon available"
      assert Tickets.get_ticket!(ticket.id).status == :planning
    end

    test "start work ignores hook loop and navigates to task loop", %{
      conn: conn,
      workspace: workspace
    } do
      insert_daemon!(%{status: :online})
      ticket = insert_ticket!(%{title: "Loop me", status: :planning, workspace_id: workspace.id})

      hook_loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :hook,
          status: :pending,
          title: "Hook: planning -> in_progress"
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets?view=list")

      view
      |> element(~s{button[phx-click="start_work"][phx-value-id="#{ticket.id}"]})
      |> render_click()

      task_loop =
        Loops.list_loops_for_ticket(ticket.id)
        |> Enum.find(&(&1.role == :task))

      assert task_loop
      assert task_loop.id != hook_loop.id

      assert_redirect(
        view,
        ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(task_loop.id, 0, 8)}?#{%{agent_type: "claude_code"}}"
      )
    end

    test "start work with planning codex ticket navigates with codex agent_type", %{
      conn: conn,
      workspace: workspace
    } do
      insert_daemon!(%{status: :online})

      ticket =
        insert_ticket!(%{
          title: "Loop me with Codex",
          status: :planning,
          coding_agent: :codex,
          workspace_id: workspace.id
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets?view=list")

      view
      |> element(~s{button[phx-click="start_work"][phx-value-id="#{ticket.id}"]})
      |> render_click()

      loop = Loops.list_task_loops_for_ticket(ticket.id) |> List.first()

      assert_redirect(
        view,
        ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(loop.id, 0, 8)}?#{%{agent_type: "codex"}}"
      )

      assert Tickets.get_ticket!(ticket.id).status == :in_progress
    end

    test "planning detail shows plan session and start work controls only", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{title: "Plan done", status: :planning, workspace_id: workspace.id})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert has_element?(view, ~s{button[phx-click="open_planning_session"]})
      assert has_element?(view, ~s{button[phx-click="start_work"]})
      refute has_element?(view, ~s{button[phx-click="mark_planning_complete"]})
    end

    test "board shows inspect when ticket has a loop id", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{title: "Has loop", status: :planning, workspace_id: workspace.id})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :pending})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      assert has_element?(
               view,
               ~s{a[href="/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(loop.id, 0, 8)}"]}
             )
    end

    test "in-progress card shows clickable stage label", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{
          title: "Running ticket",
          status: :in_progress,
          workspace_id: workspace.id
        })

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :running,
          current_attempt: 2
        })

      Algedonia.Loops.create_step(%{
        loop_id: loop.id,
        role: "maker",
        attempt: 2,
        status: "running",
        started_at: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      assert has_element?(view, ~s{a[data-role="loop-stage-link"]}, "Maker #2")
    end

    test "board shows inspect for completed ticket with loop", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{title: "Completed loop", status: :completed, workspace_id: workspace.id})

      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :passed})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      assert has_element?(
               view,
               ~s{a[href="/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(loop.id, 0, 8)}"]}
             )
    end

    test "ticket detail shows inspect when ticket has a loop id", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{title: "Inspectable", status: :halted, workspace_id: workspace.id})

      loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :failed})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert has_element?(
               view,
               ~s{a[href*="/loops/#{String.slice(loop.id, 0, 8)}"]},
               "Inspect"
             )
    end

    test "ticket detail does not show inspect when only hook loop exists", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{title: "Hook loop", status: :in_progress, workspace_id: workspace.id})

      loop = insert_loop!(%{ticket_id: ticket.id, role: :hook, status: :running})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      refute has_element?(view, ~s{a[href*="/loops/#{String.slice(loop.id, 0, 8)}"]}, "Inspect")
    end

    test "status display order places halted after in progress", %{
      conn: conn,
      workspace: workspace
    } do
      insert_ticket!(%{title: "Backlog", status: :backlog, workspace_id: workspace.id})
      insert_ticket!(%{title: "Planning", status: :planning, workspace_id: workspace.id})
      insert_ticket!(%{title: "In progress", status: :in_progress, workspace_id: workspace.id})
      insert_ticket!(%{title: "Halted", status: :halted, workspace_id: workspace.id})

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets")
      {in_progress_idx, _} = :binary.match(html, "In Progress")
      {halted_idx, _} = :binary.match(html, "Halted")

      assert in_progress_idx < halted_idx

      form_options = TicketFormComponent.status_options()
      assert Enum.map(form_options, &elem(&1, 1)) == Tickets.display_statuses()
    end
  end

  describe "Export Markdown" do
    test "ticket detail settings dropdown has export option", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{title: "Exportable", workspace_id: workspace.id})
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert html =~ "Export Markdown"
      assert html =~ "ticket-export-markdown-action"
    end

    test "clicking export redirects to export endpoint", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{title: "Exportable", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element("#ticket-export-markdown-action")
      |> render_click()

      assert_redirect(
        view,
        "/w/#{workspace.slug}/tickets/#{ticket.number}/export/markdown"
      )
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

  describe "Automations section" do
    test "shows transition automations in ticket properties", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{workspace_id: workspace.id})

      {:ok, _hook} =
        Algedonia.Workspaces.create_transition_hook(workspace, %{
          "from_status" => "planning",
          "to_status" => "in_progress",
          "instruction" => "Run pre-flight checks"
        })

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert html =~ "Automations"
      assert html =~ "Planning -&gt; In Progress"
      assert html =~ "Run pre-flight checks"
    end

    test "shows automations section when hook loops exist", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{workspace_id: workspace.id})

      insert_loop!(%{
        ticket_id: ticket.id,
        role: :hook,
        title: "Hook: backlog → planning",
        description: "Run linter",
        status: :passed
      })

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert html =~ "Automations"
      assert html =~ "Hook: backlog"
      assert html =~ "Run linter"
      assert html =~ "Passed"
    end

    test "does not show automations section when no hook loops", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{workspace_id: workspace.id})
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      refute html =~ "ticket-automations"
    end

    test "hook loops display status badges", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})

      insert_loop!(%{
        ticket_id: ticket.id,
        role: :hook,
        title: "Hook: in_progress → halted",
        status: :failed
      })

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert html =~ "Failed"
    end

    test "hook loops update via PubSub", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      # Create a hook loop externally (simulating HookExecutor)

      loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :hook,
          title: "Hook: backlog → planning",
          status: :pending
        })

      # Broadcast the event
      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.ticket_loops(workspace.id, ticket.id),
        {:hook_loop_created, loop}
      )

      assert render(view) =~ "Hook: backlog"
    end
  end
end
