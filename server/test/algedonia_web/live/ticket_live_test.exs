defmodule AlgedoniaWeb.TicketLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Ecto.Query

  alias Algedonia.{Loops, Repo, Tickets}
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

    test "modal assignee selector filters workspace members by prefix and persists selection", %{
      conn: conn,
      workspace: workspace
    } do
      alpha = insert_user!(%{name: "Alpha Modal"})
      beta = insert_user!(%{name: "Beta Modal"})
      other_workspace = insert_workspace!(%{name: "Other Modal Workspace"})
      outsider = insert_user!(%{name: "Alfred Outside"})

      insert_membership!(workspace, alpha)
      insert_membership!(workspace, beta)
      insert_membership!(other_workspace, outsider)

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      view |> element("#new-issue-button") |> render_click()

      assert has_element?(view, "#ticket-form-assignee-search")
      refute has_element?(view, ~s{#ticket-form input[name="ticket[assignee]"][type="text"]})
      refute has_element?(view, "#ticket-form-assignee-option-alpha-modal")

      html =
        view
        |> element("#ticket-form-assignee-search")
        |> render_keyup(%{"value" => "al"})

      assert html =~ "Alpha Modal"
      refute html =~ "Beta Modal"
      refute html =~ "Alfred Outside"

      view
      |> element("#ticket-form-assignee-option-alpha-modal")
      |> render_click()

      view
      |> form("#ticket-form", ticket: %{title: "Assigned from modal", type: :bug, priority: 2})
      |> render_submit()

      ticket =
        Tickets.list_tickets(workspace_id: workspace.id)
        |> Enum.find(&(&1.title == "Assigned from modal"))

      assert ticket.assignee == "Alpha Modal"

      {:ok, reload_view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert has_element?(reload_view, ~s{#ticket-detail-assignee-search[value="Alpha Modal"]})
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

    test "detail assignee selector autosaves selection and allows clearing", %{
      conn: conn,
      workspace: workspace
    } do
      alpha = insert_user!(%{name: "Alpha Detail"})
      beta = insert_user!(%{name: "Beta Detail"})
      other_workspace = insert_workspace!(%{name: "Other Detail Workspace"})
      outsider = insert_user!(%{name: "Alpine Outside"})

      insert_membership!(workspace, alpha)
      insert_membership!(workspace, beta)
      insert_membership!(other_workspace, outsider)

      ticket =
        insert_ticket!(%{title: "Detail assignee", workspace_id: workspace.id, assignee: nil})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert has_element?(view, "#ticket-detail-assignee-search")

      refute has_element?(
               view,
               ~s{#ticket-detail-form input[name="ticket[assignee]"][type="text"]}
             )

      refute has_element?(view, "#ticket-detail-assignee-option-alpha-detail")

      html =
        view
        |> element("#ticket-detail-assignee-search")
        |> render_keyup(%{"value" => "alp"})

      assert html =~ "Alpha Detail"
      refute html =~ "Beta Detail"
      refute html =~ "Alpine Outside"

      view
      |> element("#ticket-detail-assignee-option-alpha-detail")
      |> render_click()

      assert Tickets.get_ticket!(ticket.id).assignee == "Alpha Detail"

      {:ok, reload_view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert has_element?(reload_view, ~s{#ticket-detail-assignee-search[value="Alpha Detail"]})

      reload_view
      |> element("#ticket-detail-assignee-clear")
      |> render_click()

      assert Tickets.get_ticket!(ticket.id).assignee == nil
    end

    test "manual run control is only shown for in-progress and in-review tickets", %{
      conn: conn,
      workspace: workspace
    } do
      in_progress = insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})
      in_review = insert_ticket!(%{workspace_id: workspace.id, status: :in_review})
      backlog = insert_ticket!(%{workspace_id: workspace.id, status: :backlog})

      {:ok, progress_view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{in_progress}")
      {:ok, review_view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{in_review}")
      {:ok, backlog_view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{backlog}")

      assert has_element?(
               progress_view,
               ~s{#ticket-run-workspace-script[title="Run workspace script"]}
             )

      assert has_element?(
               review_view,
               ~s{#ticket-run-workspace-script[title="Run workspace script"]}
             )

      refute has_element?(backlog_view, "#ticket-run-workspace-script")
    end

    test "manual run is blocked when no workspace run script is configured", %{
      conn: conn,
      workspace: workspace
    } do
      daemon = insert_daemon!(%{status: :online})
      topic = "daemon:#{daemon.name}"
      AlgedoniaWeb.Endpoint.subscribe(topic)

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      html = render_click(view, "run_workspace_script", %{"id" => ticket.id})

      assert html =~ "Set a workspace run script in Settings before running it"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "run_workspace_script"}, 100
    end

    test "manual run dispatches a ticket-scoped daemon command and disables duplicate clicks", %{
      conn: conn,
      workspace: workspace
    } do
      daemon = insert_daemon!(%{status: :online})
      topic = "daemon:#{daemon.name}"
      AlgedoniaWeb.Endpoint.subscribe(topic)

      {:ok, workspace} =
        Algedonia.Workspaces.update_workspace(workspace, %{
          worktree_run_script: "bin/verify-ticket"
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element("#ticket-run-workspace-script")
      |> render_click()

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "run_workspace_script",
                       payload: %{
                         "run_id" => run_id,
                         "workspace_slug" => workspace_slug,
                         "ticket_id" => ticket_id,
                         "worktree_run_script" => script
                       }
                     },
                     1000

      assert workspace_slug == workspace.slug
      assert ticket_id == ticket.id
      assert script == "bin/verify-ticket"

      assert has_element?(view, ~s{#ticket-run-workspace-script[disabled]})

      html = render_click(view, "run_workspace_script", %{"id" => ticket.id})

      assert html =~ "Workspace script is already running"

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.ticket_manual_run(workspace.id, ticket.id),
        {:manual_run_complete,
         %{
           "run_id" => run_id,
           "status" => "succeeded",
           "exit_code" => 0,
           "completed_at" => "2026-03-14T12:00:00Z"
         }}
      )

      assert render(view) =~ "Exit code 0"
    end

    test "manual run panel keeps only the latest run output", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id, status: :in_review})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      topic = Topics.ticket_manual_run(workspace.id, ticket.id)

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        topic,
        {:manual_run_started,
         %{
           "run_id" => "11111111-1111-4111-8111-111111111111",
           "started_at" => "2026-03-14T10:00:00Z"
         }}
      )

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        topic,
        {:manual_run_output,
         %{
           "run_id" => "11111111-1111-4111-8111-111111111111",
           "data" => "first run output"
         }}
      )

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        topic,
        {:manual_run_complete,
         %{
           "run_id" => "11111111-1111-4111-8111-111111111111",
           "status" => "failed",
           "exit_code" => 2,
           "completed_at" => "2026-03-14T10:01:00Z"
         }}
      )

      assert render(view) =~ "first run output"
      assert render(view) =~ "Exit code 2"

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        topic,
        {:manual_run_started,
         %{
           "run_id" => "22222222-2222-4222-8222-222222222222",
           "started_at" => "2026-03-14T11:00:00Z"
         }}
      )

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        topic,
        {:manual_run_output,
         %{
           "run_id" => "22222222-2222-4222-8222-222222222222",
           "data" => "second run output"
         }}
      )

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        topic,
        {:manual_run_complete,
         %{
           "run_id" => "22222222-2222-4222-8222-222222222222",
           "status" => "succeeded",
           "exit_code" => 0,
           "completed_at" => "2026-03-14T11:01:00Z"
         }}
      )

      html = render(view)
      assert html =~ "second run output"
      assert html =~ "Exit code 0"
      refute html =~ "first run output"
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

    test "status columns default to updated_at desc on first load", %{
      conn: conn,
      workspace: workspace
    } do
      backlog_older =
        insert_ticket!(%{
          title: "Backlog older",
          status: :backlog,
          workspace_id: workspace.id
        })

      backlog_newer =
        insert_ticket!(%{
          title: "Backlog newer",
          status: :backlog,
          workspace_id: workspace.id
        })

      older =
        insert_ticket!(%{
          title: "Completed older",
          status: :completed,
          workspace_id: workspace.id
        })

      newer =
        insert_ticket!(%{
          title: "Completed newer",
          status: :completed,
          workspace_id: workspace.id
        })

      set_ticket_updated_at!(backlog_older, ~U[2025-01-01 00:00:00Z])
      set_ticket_updated_at!(older, ~U[2025-01-01 00:00:00Z])
      set_ticket_updated_at!(backlog_newer, ~U[2025-02-01 00:00:00Z])
      set_ticket_updated_at!(newer, ~U[2025-02-01 00:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      assert has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Updated descending"]}
             )

      assert has_element?(
               view,
               ~s{#ticket-sort-completed[aria-label="Sort Completed: Updated descending"]}
             )

      refute has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Updated desc"]}
             )

      refute has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Updated asc"]}
             )

      assert_ordered_titles(render_board_column(view, :backlog), [
        "Backlog newer",
        "Backlog older"
      ])

      assert_ordered_titles(render_board_column(view, :completed), [
        "Completed newer",
        "Completed older"
      ])
    end

    test "sorting field and direction reorder only the targeted status column", %{
      conn: conn,
      workspace: workspace
    } do
      alpha_backlog =
        insert_ticket!(%{
          title: "Alpha backlog",
          priority: 5,
          status: :backlog,
          workspace_id: workspace.id
        })

      zulu_backlog =
        insert_ticket!(%{
          title: "Zulu backlog",
          priority: 1,
          status: :backlog,
          workspace_id: workspace.id
        })

      older =
        insert_ticket!(%{
          title: "Completed older",
          status: :completed,
          workspace_id: workspace.id
        })

      newer =
        insert_ticket!(%{
          title: "Completed newer",
          status: :completed,
          workspace_id: workspace.id
        })

      set_ticket_updated_at!(older, ~U[2025-01-01 00:00:00Z])
      set_ticket_updated_at!(newer, ~U[2025-02-01 00:00:00Z])
      set_ticket_updated_at!(alpha_backlog, ~U[2025-02-01 00:00:00Z])
      set_ticket_updated_at!(zulu_backlog, ~U[2025-01-01 00:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      assert has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Updated descending"]}
             )

      assert_ordered_titles(render_board_column(view, :backlog), ["Alpha backlog", "Zulu backlog"])

      assert_ordered_titles(render_board_column(view, :completed), [
        "Completed newer",
        "Completed older"
      ])

      view
      |> element(
        ~s{button[phx-click="set_status_sort"][phx-value-status="backlog"][phx-value-sort_by="title"]}
      )
      |> render_click()

      assert has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Title descending"]}
             )

      assert_ordered_titles(render_board_column(view, :backlog), ["Zulu backlog", "Alpha backlog"])

      view
      |> element(
        ~s{button[phx-click="set_status_sort"][phx-value-status="backlog"][phx-value-sort_order="asc"]}
      )
      |> render_click()

      assert has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Title ascending"]}
             )

      assert_ordered_titles(render_board_column(view, :backlog), ["Alpha backlog", "Zulu backlog"])

      assert has_element?(
               view,
               ~s{#ticket-sort-completed[aria-label="Sort Completed: Updated descending"]}
             )

      assert_ordered_titles(render_board_column(view, :completed), [
        "Completed newer",
        "Completed older"
      ])

      view
      |> element(
        ~s{button[phx-click="set_status_sort"][phx-value-status="backlog"][phx-value-sort_order="desc"]}
      )
      |> render_click()

      assert has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Title descending"]}
             )

      assert_ordered_titles(render_board_column(view, :backlog), ["Zulu backlog", "Alpha backlog"])
    end

    test "restore_prefs reapplies saved view and per-status sort preferences", %{
      conn: conn,
      workspace: workspace
    } do
      insert_ticket!(%{
        title: "Alpha backlog",
        priority: 1,
        status: :backlog,
        workspace_id: workspace.id
      })

      insert_ticket!(%{
        title: "Zulu backlog",
        priority: 5,
        status: :backlog,
        workspace_id: workspace.id
      })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      render_hook(view, "restore_prefs", %{
        "view_mode" => "list",
        "sort_preferences" => %{
          "backlog" => %{"sort_by" => "title", "sort_order" => "desc"}
        }
      })

      assert_patch(view, ~p"/w/#{workspace.slug}/tickets?view=list")

      assert has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Title descending"]}
             )

      refute has_element?(
               view,
               ~s{#ticket-sort-backlog[aria-label="Sort Backlog: Title desc"]}
             )

      assert_ordered_titles(render_list_section(view, :backlog), ["Zulu backlog", "Alpha backlog"])
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

      loop = insert_loop!(%{ticket_id: ticket.id, role: :planning, status: :pending})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert has_element?(view, ~s{button[phx-click="open_planning_session"]})
      assert has_element?(view, ~s{button[phx-click="start_work"]})
      refute has_element?(view, ~s{button[phx-click="mark_planning_complete"]})
      refute has_element?(view, ~s{a[href*="/loops/#{String.slice(loop.id, 0, 8)}"]}, "Inspect")
    end

    test "board hides inspect for planning tickets even when loop exists", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{title: "Has loop", status: :planning, workspace_id: workspace.id})
      loop = insert_loop!(%{ticket_id: ticket.id, role: :planning, status: :pending})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      refute has_element?(view, ~s{a[href*="/loops/#{String.slice(loop.id, 0, 8)}"]}, "Inspect")
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

    test "ticket detail review button targets the review loop, not the task loop", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        insert_ticket!(%{title: "Reviewable", status: :in_review, workspace_id: workspace.id})

      task_loop = insert_loop!(%{ticket_id: ticket.id, role: :task, status: :passed})
      review_loop = insert_loop!(%{ticket_id: ticket.id, role: :review, status: :running})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert has_element?(
               view,
               ~s{a[href*="/loops/#{String.slice(review_loop.id, 0, 8)}"]},
               "Review"
             )

      refute has_element?(
               view,
               ~s{a[href*="/loops/#{String.slice(task_loop.id, 0, 8)}"]},
               "Review"
             )

      assert has_element?(
               view,
               ~s{a[href*="/loops/#{String.slice(task_loop.id, 0, 8)}"]},
               "Inspect"
             )
    end

    test "board in_review card routes Review to the review loop when task and review loops are both active",
         %{
           conn: conn,
           workspace: workspace
         } do
      ticket =
        insert_ticket!(%{title: "Review card", status: :in_review, workspace_id: workspace.id})

      task_loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :running,
          current_attempt: 2
        })

      review_loop =
        insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          current_attempt: 1
        })

      Algedonia.Loops.create_step(%{
        loop_id: task_loop.id,
        role: "maker",
        attempt: 2,
        status: "running",
        started_at: DateTime.add(DateTime.utc_now(), -5, :second)
      })

      Algedonia.Loops.create_step(%{
        loop_id: review_loop.id,
        role: "review",
        attempt: 1,
        status: "running",
        started_at: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

      review_href =
        ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(review_loop.id, 0, 8)}"

      task_href =
        ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(task_loop.id, 0, 8)}"

      review_link_html =
        view
        |> element(~s{a[data-role="loop-stage-link"][href="#{review_href}"]})
        |> render()

      assert review_link_html =~ ~s{href="#{review_href}"}
      assert review_link_html =~ ~r/>\s*Review\s*</
      refute review_link_html =~ "Review #"
      refute review_link_html =~ "Maker #"
      refute has_element?(view, ~s{a[data-role="loop-stage-link"][href="#{task_href}"]}, "Review")
      refute render(view) =~ "Pull Comments"
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

    test "form status options include In Review label" do
      assert {"In Review", :in_review} in TicketFormComponent.status_options()
    end
  end

  describe "Land Mode" do
    test "ticket detail shows land mode selector with inherited default", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{workspace_id: workspace.id})
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert html =~ "Land Mode"
      assert html =~ "Inherited (Review Gate)"
    end

    test "ticket detail shows effective land mode from workspace default", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, _} =
        Algedonia.Workspaces.update_workspace(workspace, %{
          defaults: %{"land_mode" => "auto_land"}
        })

      ticket = insert_ticket!(%{workspace_id: workspace.id})
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")
      assert html =~ "Inherited (Auto Land)"
    end

    test "saving land mode persists override on ticket", %{conn: conn, workspace: workspace} do
      ticket = insert_ticket!(%{workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> form("#ticket-detail-form", ticket: %{land_mode: "auto_land"})
      |> render_change()

      reloaded = Algedonia.Tickets.get_ticket!(ticket.id)
      assert reloaded.land_mode == :auto_land
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

  describe "Blocked-by / Depends On" do
    test "create form keeps Depends On collapsed until expanded", %{
      conn: conn,
      workspace: workspace
    } do
      insert_ticket!(%{title: "Blocker ticket", workspace_id: workspace.id})
      {:ok, view, initial_html} = live(conn, ~p"/w/#{workspace.slug}/tickets/new")

      assert initial_html =~ "Depends On"
      assert has_element?(view, "#ticket-form-expand-depends-on")
      refute has_element?(view, "#ticket-form-blocked-by")

      html =
        view
        |> element("#ticket-form-expand-depends-on")
        |> render_click()

      refute has_element?(view, "#ticket-form-expand-depends-on")
      assert has_element?(view, "#ticket-form-blocked-by")
      assert html =~ "Blocker ticket"
    end

    test "create form persists blocked_by on submit after expanding Depends On", %{
      conn: conn,
      workspace: workspace
    } do
      blocker = insert_ticket!(%{title: "Must finish first", workspace_id: workspace.id})

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/new")

      view
      |> element("#ticket-form-expand-depends-on")
      |> render_click()

      view
      |> form("#ticket-form",
        ticket: %{
          title: "Dependent ticket",
          type: :feature,
          priority: 3,
          blocked_by: [blocker.id]
        }
      )
      |> render_submit()

      dependent =
        Tickets.list_tickets(workspace_id: workspace.id)
        |> Enum.find(&(&1.title == "Dependent ticket"))

      assert dependent
      assert dependent.blocked_by == [blocker.id]
    end

    test "edit form shows Depends On with current blockers selected", %{
      conn: conn,
      workspace: workspace
    } do
      blocker = insert_ticket!(%{title: "Blocker A", workspace_id: workspace.id})

      ticket =
        insert_ticket!(%{
          title: "Blocked ticket",
          workspace_id: workspace.id,
          blocked_by: [blocker.id]
        })

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}/edit")

      assert html =~ "Depends On"
      assert html =~ "Blocker A"
    end

    test "detail sidebar shows Depends On section with blocker links", %{
      conn: conn,
      workspace: workspace
    } do
      blocker = insert_ticket!(%{title: "Setup CI", workspace_id: workspace.id})

      ticket =
        insert_ticket!(%{
          title: "Needs CI",
          workspace_id: workspace.id,
          blocked_by: [blocker.id]
        })

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert html =~ "Depends On"
      assert html =~ "Setup CI"
      assert html =~ "/w/#{workspace.slug}/tickets/#{blocker.number}"
    end

    test "detail sidebar shows no-tickets message when workspace has only one ticket", %{
      conn: conn,
      workspace: workspace
    } do
      ticket = insert_ticket!(%{title: "Free ticket", workspace_id: workspace.id})
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert html =~ "Depends On"
      assert html =~ "No other tickets available"
    end

    test "detail sidebar hides blocker options until searched and hides them again on clear", %{
      conn: conn,
      workspace: workspace
    } do
      insert_ticket!(%{title: "Alpha blocker", workspace_id: workspace.id})
      insert_ticket!(%{title: "Beta blocker", workspace_id: workspace.id})
      ticket = insert_ticket!(%{title: "Ticket under test", workspace_id: workspace.id})
      {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      assert html =~ "Depends On"
      assert has_element?(view, "#detail-blocked-by-search")
      refute has_element?(view, "#detail-blocked-by")
      refute html =~ "Alpha blocker"
      refute html =~ "Beta blocker"

      html =
        view
        |> element("#detail-blocked-by-search")
        |> render_keyup(%{"value" => "alp"})

      assert has_element?(view, "#detail-blocked-by")
      assert html =~ "Alpha blocker"
      refute html =~ "Beta blocker"

      html =
        view
        |> element("#detail-blocked-by-search")
        |> render_keyup(%{"value" => ""})

      refute has_element?(view, "#detail-blocked-by")
      refute html =~ "Alpha blocker"
      refute html =~ "Beta blocker"
    end

    test "detail sidebar persists blocked_by via autosave", %{
      conn: conn,
      workspace: workspace
    } do
      blocker = insert_ticket!(%{title: "New blocker", workspace_id: workspace.id})
      ticket = insert_ticket!(%{title: "Will be blocked", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element("#detail-blocked-by-search")
      |> render_keyup(%{"value" => "new"})

      view
      |> form("#ticket-detail-form", ticket: %{blocked_by: [blocker.id]})
      |> render_change()

      updated = Tickets.get_ticket!(ticket.id)
      assert updated.blocked_by == [blocker.id]
    end

    test "detail sidebar shows blocker links after save and on pubsub update", %{
      conn: conn,
      workspace: workspace
    } do
      blocker = insert_ticket!(%{title: "New blocker", workspace_id: workspace.id})
      ticket = insert_ticket!(%{title: "Will be blocked", workspace_id: workspace.id})
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element("#detail-blocked-by-search")
      |> render_keyup(%{"value" => "new"})

      view
      |> form("#ticket-detail-form", ticket: %{blocked_by: [blocker.id]})
      |> render_change()

      html = render(view)
      assert html =~ "New blocker"
      assert html =~ "/w/#{workspace.slug}/tickets/#{blocker.number}"

      # Also verify PubSub path refreshes blocker data
      updated = Tickets.get_ticket!(ticket.id)
      send(view.pid, {:ticket_updated, updated})

      html = render(view)
      assert html =~ "New blocker"
    end

    test "detail sidebar shows validation error for cycle in blocked_by", %{
      conn: conn,
      workspace: workspace
    } do
      ticket_a = insert_ticket!(%{title: "Ticket A", workspace_id: workspace.id})

      ticket_b =
        insert_ticket!(%{
          title: "Ticket B",
          workspace_id: workspace.id,
          blocked_by: [ticket_a.id]
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket_a}")

      view
      |> element("#detail-blocked-by-search")
      |> render_keyup(%{"value" => "ticket b"})

      html =
        view
        |> form("#ticket-detail-form", ticket: %{blocked_by: [ticket_b.id]})
        |> render_change()

      assert html =~ "cycle"
    end

    test "detail sidebar does not discard persisted blockers on validation error", %{
      conn: conn,
      workspace: workspace
    } do
      blocker = insert_ticket!(%{title: "Valid blocker", workspace_id: workspace.id})

      ticket =
        insert_ticket!(%{
          title: "Has blocker",
          workspace_id: workspace.id,
          blocked_by: [blocker.id]
        })

      cycle_target =
        insert_ticket!(%{
          title: "Cycle target",
          workspace_id: workspace.id,
          blocked_by: [ticket.id]
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket}")

      view
      |> element("#detail-blocked-by-search")
      |> render_keyup(%{"value" => "cycle"})

      # Attempt a cycle — should show error
      html =
        view
        |> form("#ticket-detail-form", ticket: %{blocked_by: [cycle_target.id]})
        |> render_change()

      assert html =~ "cycle"

      # Persisted value should be unchanged
      persisted = Tickets.get_ticket!(ticket.id)
      assert persisted.blocked_by == [blocker.id]
    end

    test "form shows validation error for cycle", %{conn: conn, workspace: workspace} do
      ticket_a =
        insert_ticket!(%{title: "Ticket A", workspace_id: workspace.id})

      ticket_b =
        insert_ticket!(%{
          title: "Ticket B",
          workspace_id: workspace.id,
          blocked_by: [ticket_a.id]
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket_a}/edit")

      html =
        view
        |> form("#ticket-form", ticket: %{blocked_by: [ticket_b.id]})
        |> render_submit()

      assert html =~ "cycle"
    end
  end

  defp render_board_column(view, status) do
    view
    |> element("#col-#{status}")
    |> render()
  end

  defp render_list_section(view, status) do
    view
    |> element("#list-#{status}")
    |> render()
  end

  defp assert_ordered_titles(html, [first, second | rest]) do
    first_index = title_index!(html, first)
    second_index = title_index!(html, second)

    assert first_index < second_index

    assert_ordered_titles(html, [second | rest])
  end

  defp assert_ordered_titles(_html, [_last]), do: :ok

  defp set_ticket_updated_at!(ticket, updated_at) do
    from(t in Algedonia.Tickets.Ticket, where: t.id == ^ticket.id)
    |> Repo.update_all(set: [updated_at: updated_at])

    Tickets.get_ticket!(ticket.id)
  end

  defp title_index!(html, title) do
    case :binary.match(html, title) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{inspect(title)} to appear in rendered HTML")
    end
  end
end
