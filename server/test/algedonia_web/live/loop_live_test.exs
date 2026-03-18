defmodule AlgedoniaWeb.LoopLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Algedonia.{Factory, Loops, Terminals, Tickets}
  alias Algedonia.PubSub.Topics

  describe "Show" do
    test "mounts and renders loop_id", %{conn: conn, workspace: workspace} do
      loop_id = "11111111-1111-4111-8111-111111111111"

      {:ok, view, html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      assert html =~ loop_id
      assert has_element?(view, "[id^=terminal-attempt-]")
    end

    test "does not show start or stop buttons", %{conn: conn, workspace: workspace} do
      loop_id = "22222222-2222-4222-8222-222222222222"

      {:ok, _view, html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      refute html =~ "Start Loop"
      refute html =~ "Stop Loop"
    end

    test "pending loop auto-starts on mount", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{status: :pending})

      {:ok, view, _html} =
        live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      # Auto-start sends :auto_start_loop which calls start_loop_on_daemon
      # Without a daemon, it shows a flash error
      html = render(view)
      assert html =~ "No online daemon available"
    end

    test "passed loop does NOT auto-start (view-only)", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{status: :passed, current_attempt: 1})

      {:ok, view, html} =
        live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      refute html =~ "Start Loop"
      refute html =~ "No online daemon available"
      # Re-render to confirm no auto-start was triggered
      refute render(view) =~ "No online daemon available"
    end

    test "failed loop does NOT auto-start (view-only)", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{status: :failed, current_attempt: 3})

      {:ok, view, html} =
        live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      refute html =~ "Start Loop"
      refute render(view) =~ "No online daemon available"
    end

    test "pending hook loop does NOT auto-start", %{conn: conn, workspace: workspace} do
      ticket = Factory.insert_ticket!(%{workspace_id: workspace.id, status: :planning})

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :hook,
          status: :pending,
          title: "Hook: planning -> in_progress"
        })

      {:ok, view, html} =
        live(conn, "/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{loop.id}")

      refute html =~ "No online daemon available"
      refute render(view) =~ "No online daemon available"
    end

    test "planning session with real loop loads ticket context", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :planning,
          title: "Plan this"
        })

      {:ok, loop_id} = Algedonia.Tickets.start_planning_work(ticket)

      {:ok, _view, html} =
        live(
          conn,
          ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(loop_id, 0, 8)}?#{%{role: "planning"}}"
        )

      assert html =~ "Planning: Plan this"
    end

    test "planning session auto-starts on mount", %{conn: conn, workspace: workspace} do
      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :planning,
          title: "Plan this"
        })

      {:ok, planning_loop_id} = Algedonia.Tickets.start_planning_work(ticket)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(planning_loop_id, 0, 8)}?#{%{role: "planning"}}"
        )

      assert render(view) =~ "No online daemon available"
    end

    test "planning session restart reuses the interrupted step", %{
      conn: conn,
      workspace: workspace
    } do
      _daemon = Factory.insert_daemon!(%{status: :online})

      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :planning,
          title: "Resume planning"
        })

      {:ok, planning_loop_id} = Tickets.start_planning_work(ticket)
      loop = Loops.get_loop!(planning_loop_id)
      [step] = Loops.list_steps_for_loop(planning_loop_id)

      Loops.interrupt_running_steps(planning_loop_id)
      {:ok, _loop} = Loops.update_loop(loop, %{status: :pending, assigned_daemon_id: nil})

      {:ok, _view, _html} =
        live(
          conn,
          ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(planning_loop_id, 0, 8)}?#{%{role: "planning"}}"
        )

      Process.sleep(100)

      [resumed_step] = Loops.list_steps_for_loop(planning_loop_id)
      assert resumed_step.id == step.id
      assert resumed_step.status == "running"
    end

    test "planning role shows sidebar but hides top-bar maker/index indicators", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :planning,
          title: "Plan this"
        })

      {:ok, persisted_loop_id} = Algedonia.Tickets.start_planning_work(ticket)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{String.slice(persisted_loop_id, 0, 8)}?#{%{role: "planning"}}"
        )

      assert has_element?(view, "#loop-left-sidebar-panel")
      refute has_element?(view, "#loop-index-badge")
      refute has_element?(view, "#loop-terminal-panel .h-12 span", "maker")
    end

    test "review loop shows pull comments button and external view pr link in top bar", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, workspace} =
        Algedonia.Workspaces.update_workspace(workspace, %{
          github_repo_url: "https://github.com/test/repo"
        })

      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :in_review,
          title: "Review this",
          review_pr_number: 42
        })

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          current_attempt: 1
        })

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{loop.id}")

      assert has_element?(
               view,
               "#loop-terminal-panel button[phx-click='pull_comments']",
               "Pull Comments"
             )

      refute has_element?(
               view,
               "#loop-terminal-panel button[phx-click='pull_comments'][disabled]"
             )

      assert has_element?(
               view,
               "#loop-terminal-panel a[href='https://github.com/test/repo/pull/42'][target='_blank'][rel='noopener noreferrer']",
               "View PR"
             )

      refute has_element?(view, "#loop-terminal-panel a[phx-click='merge_pr']")
      refute has_element?(view, "#loop-terminal-panel button[phx-click='merge_pr']")
      refute render(view) =~ "Merge"
    end

    test "review loop hides pull comments and view pr controls until a PR is linked", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :in_review,
          title: "Review this",
          review_pr_number: nil
        })

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          current_attempt: 1
        })

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{loop.id}")

      refute has_element?(view, "#loop-terminal-panel button[phx-click='pull_comments']")
      refute has_element?(view, "#loop-terminal-panel button[phx-click='merge_pr']")
      refute has_element?(view, "#loop-terminal-panel a[target='_blank']", "View PR")
      refute render(view) =~ "Pull Comments"
      refute render(view) =~ "View PR"
      refute render(view) =~ "Merge"
    end

    test "review loop shows last polled timestamp subtly", %{conn: conn, workspace: workspace} do
      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :in_review,
          title: "Review poll",
          review_pr_number: 42
        })

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          current_attempt: 1
        })

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{loop.id}")

      send(
        view.pid,
        {:review_poll_state, loop.id,
         %{last_polled_at: ~U[2026-03-09 06:00:00Z], feedback_token: "abc", ci_state: "success"}}
      )

      assert render(view) =~ "Polled 06:00:00"
    end

    test "pull_comments without linked PR flashes error and does not dispatch review actions", %{
      conn: conn,
      workspace: workspace
    } do
      daemon = Factory.insert_daemon!(%{status: :online})
      topic = "daemon:#{daemon.name}"
      AlgedoniaWeb.Endpoint.subscribe(topic)

      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :in_review,
          title: "Review this",
          review_pr_number: nil
        })

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{loop.id}")

      html = render_click(view, "pull_comments", %{})

      assert html =~ "No pull request is linked to this ticket yet"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "start_loop"}, 100
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "stdin_input"}, 100
    end

    test "merge_pr without linked PR flashes error and does not dispatch merge action", %{
      conn: conn,
      workspace: workspace
    } do
      daemon = Factory.insert_daemon!(%{status: :online})
      topic = "daemon:#{daemon.name}"
      AlgedoniaWeb.Endpoint.subscribe(topic)

      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :in_review,
          title: "Review this",
          review_pr_number: nil
        })

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          assigned_daemon_id: daemon.id,
          current_attempt: 1
        })

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{loop.id}")

      html = render_click(view, "merge_pr", %{})

      assert html =~ "No pull request is linked to this ticket yet"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "merge_pr"}, 100
    end

    test "terminal image drop requires an active loop terminal", %{
      conn: conn,
      workspace: workspace
    } do
      loop = build_task_loop!(workspace, %{status: :running, current_attempt: 1})

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/#{loop.ticket_id}/loops/#{loop.id}")

      html =
        view
        |> element("[id^='terminal-attempt-1-']")
        |> render_hook("terminal_image_drop_upload", %{
          "files" => [%{"name" => "shot.png", "type" => "image/png", "data" => "YWJj"}]
        })

      assert html =~ "Image drop requires an active loop terminal"
    end

    test "terminal image drop without daemon flashes and does not dispatch upload", %{
      conn: conn,
      workspace: workspace
    } do
      loop = build_task_loop!(workspace, %{status: :running, current_attempt: 1})
      topic = "daemon:test-daemon"
      AlgedoniaWeb.Endpoint.subscribe(topic)
      Terminals.start_buffer(loop.id)

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/#{loop.ticket_id}/loops/#{loop.id}")

      html =
        view
        |> element("[id^='terminal-attempt-1-']")
        |> render_hook("terminal_image_drop_upload", %{
          "files" => [%{"name" => "shot.png", "type" => "image/png", "data" => "YWJj"}]
        })

      assert html =~ "No online daemon available"

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "terminal_image_drop_upload"
                     },
                     100
    end

    test "terminal image drop result flashes explicit feedback", %{
      conn: conn,
      workspace: workspace
    } do
      loop = build_task_loop!(workspace, %{status: :running, current_attempt: 1})

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/#{loop.ticket_id}/loops/#{loop.id}")

      send(
        view.pid,
        {:terminal_image_drop_result, :error, "Dropped images could not be written to /tmp."}
      )

      assert render(view) =~ "Dropped images could not be written to /tmp."
    end

    test "stale planning URL with non-UUID ref self-heals to real planning loop", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :planning,
          title: "Stale plan"
        })

      # Simulate a stale URL using short_id(ticket.id) as the loop_ref — no matching loop exists
      stale_ref = String.slice(ticket.id, 0, 8)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{stale_ref}?#{%{role: "planning"}}"
        )

      # The view should self-heal: ensure_planning_loop creates a real loop
      loop_id = :sys.get_state(view.pid).socket.assigns.loop_id
      assert {:ok, _} = Ecto.UUID.cast(loop_id)

      # A planning loop should now exist for this ticket
      planning_loops = Loops.list_planning_loops_for_ticket(ticket.id)
      assert [%{role: :planning}] = planning_loops
    end

    test "planning loop_id sent to daemon is always a full UUID", %{
      conn: conn,
      workspace: workspace
    } do
      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :planning,
          title: "UUID check"
        })

      stale_ref = String.slice(ticket.id, 0, 8)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/w/#{workspace.slug}/tickets/#{ticket.number}/loops/#{stale_ref}?#{%{role: "planning"}}"
        )

      loop_id = :sys.get_state(view.pid).socket.assigns.loop_id

      assert String.length(loop_id) == 36

      assert String.match?(
               loop_id,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
             )
    end

    test "renders split panel shell with resize handle and persistence wiring", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "33333333-3333-4333-8333-333333333333"

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      assert has_element?(
               view,
               "#loop-inspector-layout[phx-hook='SplitPanel'][data-storage-key='loop-inspector-width']"
             )

      assert has_element?(view, "#loop-terminal-panel[data-split-left]")
      assert has_element?(view, "#loop-inspector-panel[data-split-right]")
      assert has_element?(view, "#loop-inspector-resize-handle[data-split-handle]")
    end

    test "layout uses CSS var fallbacks without fixed inline width defaults", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "44444444-4444-4444-8444-444444444444"

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      refute has_element?(view, "#loop-workspace-layout[style*='--left-sidebar-width']")
      refute has_element?(view, "#loop-inspector-layout[style*='--inspector-width']")

      assert has_element?(view, "#loop-workspace-layout[phx-hook='SidebarPanel']")
      assert has_element?(view, "#loop-workspace-layout[data-storage-key='left-sidebar-width']")
      assert has_element?(view, "#loop-workspace-layout [data-sidebar-toggle]")
      assert has_element?(view, "#loop-workspace-layout[data-collapsed-width='52']")
      assert has_element?(view, "#loop-inspector-layout[phx-hook='SplitPanel']")
    end

    test "sends scrollback on connect when buffer exists", %{conn: conn, workspace: workspace} do
      loop_id = Ecto.UUID.generate()
      Terminals.append(loop_id, "prior output")

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      # The scrollback is sent as a push_event
      assert render(view) =~ loop_id
    end

    test "receives PubSub terminal data updates", %{conn: conn, workspace: workspace} do
      loop_id = Ecto.UUID.generate()
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      # Simulate terminal data arriving via PubSub
      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.terminal(workspace.id, loop_id),
        {:terminal_data, loop_id, "new output"}
      )

      # The LiveView should handle it without crashing
      assert render(view) =~ loop_id
    end

    test "handles terminal data bursts without crashing", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = Ecto.UUID.generate()
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.terminal(workspace.id, loop_id),
        {:terminal_data, loop_id, "foo"}
      )

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.terminal(workspace.id, loop_id),
        {:terminal_data, loop_id, "bar"}
      )

      assert render(view) =~ loop_id
    end

    test "handles terminal_ended event", %{conn: conn, workspace: workspace} do
      loop_id = Ecto.UUID.generate()
      Terminals.start_buffer(loop_id)

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.terminal(workspace.id, loop_id),
        {:terminal_data, loop_id, "tail output"}
      )

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.terminal(workspace.id, loop_id),
        {:terminal_ended, loop_id, 0}
      )

      assert_push_event(view, "terminal_ended", %{exit_code: 0})
    end

    test "does not render history sidebar tab and toggles steps panel", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "55555555-5555-4555-8555-555555555555"

      {:ok, view, html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      refute html =~ "History"

      refute has_element?(view, "button[phx-click='select_step']")
      render_click(element(view, "button[phx-click='toggle_steps']"))
      assert render(view) =~ "No maker/checker runs yet."
    end

    test "renders step tabs and switches terminal label when selecting a step", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = Ecto.UUID.generate()
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      send(view.pid, {:loop_history_updated, step_history_fixture()})

      render_click(element(view, "button[phx-click='toggle_steps']"))
      html = render(view)
      assert html =~ "Maker #1"
      assert html =~ "Checker #1"
      assert has_element?(view, "button[phx-value-step_id='step-checker-1'] .animate-spin")

      render_click(element(view, "button[phx-value-step_id='step-checker-1']"))
      assert has_element?(view, "#attempt-1-checker-step-checker-1")
    end

    test "auto-follows maker to checker transition for selected chip and terminal panel", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = Ecto.UUID.generate()
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      send(view.pid, {:loop_history_updated, maker_running_history_fixture()})
      render_click(element(view, "button[phx-click='toggle_steps']"))

      assert has_element?(
               view,
               "button[phx-value-step_id='step-maker-1'][class*='border-accent-indigo/60']"
             )

      assert has_element?(view, "#attempt-1-maker-step-maker-1")

      send(view.pid, {:loop_history_updated, step_history_fixture()})

      assert has_element?(
               view,
               "button[phx-value-step_id='step-checker-1'][class*='border-accent-indigo/60']"
             )

      refute has_element?(
               view,
               "button[phx-value-step_id='step-maker-1'][class*='border-accent-indigo/60']"
             )

      assert has_element?(view, "#attempt-1-checker-step-checker-1")
    end

    test "orders out-of-order history and marks checker as current when running", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = Ecto.UUID.generate()
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      send(view.pid, {:loop_history_updated, out_of_order_running_checker_history_fixture()})

      render_click(element(view, "button[phx-click='toggle_steps']"))
      html = render(view)

      assert has_element?(view, "button[phx-value-step_id='step-checker-1'] .animate-spin")
      assert has_element?(view, "#attempt-1-checker-step-checker-1")
      assert html =~ ~r/Maker #1.*Checker #1/s
    end

    test "auto-follow selects newest completed step when no step is running", %{
      conn: conn,
      workspace: workspace
    } do
      loop =
        build_task_loop!(workspace, %{
          status: :running,
          current_attempt: 1
        })

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")
      send(view.pid, {:loop_history_updated, no_running_checker_current_history_fixture()})

      render_click(element(view, "button[phx-click='toggle_steps']"))

      assert has_element?(
               view,
               "button[phx-value-step_id='step-checker-1'][class*='border-accent-indigo/60']"
             )

      assert has_element?(view, "#attempt-1-checker-step-checker-1")
    end

    test "manual step selection stays pinned across history updates while spinner tracks current step",
         %{
           conn: conn,
           workspace: workspace
         } do
      loop =
        build_task_loop!(workspace, %{
          status: :running,
          current_attempt: 2
        })

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")
      send(view.pid, {:loop_history_updated, older_selected_running_current_history_fixture()})

      render_click(element(view, "button[phx-click='toggle_steps']"))
      render_click(element(view, "button[phx-value-step_id='step-maker-1']"))

      assert has_element?(
               view,
               "button[phx-value-step_id='step-maker-1'][class*='border-accent-indigo/60']"
             )

      assert has_element?(view, "#attempt-1-maker-step-maker-1")
      assert has_element?(view, "button[phx-value-step_id='step-checker-2'] .animate-spin")

      send(view.pid, {:loop_history_updated, newer_running_checker_history_fixture()})

      assert has_element?(
               view,
               "button[phx-value-step_id='step-maker-1'][class*='border-accent-indigo/60']"
             )

      refute has_element?(
               view,
               "button[phx-value-step_id='step-checker-3'][class*='border-accent-indigo/60']"
             )

      assert has_element?(view, "#attempt-1-maker-step-maker-1")
      assert has_element?(view, "button[phx-value-step_id='step-checker-3'] .animate-spin")
    end

    test "switches to rubric tab and renders collaborative editor shell", %{
      conn: conn,
      workspace: workspace
    } do
      loop = build_task_loop!(workspace, %{rubric: "Start"})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      refute has_element?(view, ".rubric-editor-shell")
      render_click(element(view, "button[phx-value-tab='rubric']"))

      _html = render(view)
      assert has_element?(view, ".rubric-editor-shell")
      assert has_element?(view, "#rubric-editor")
    end

    test "shortcut help includes inspector toggle shortcut", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "66666666-6666-4666-8666-666666666666"

      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      render_hook(view, "toggle_shortcut_help", %{})

      html = render(view)
      assert html =~ "Toggle inspector panel"
      assert html =~ "Ctrl"
    end

    test "persists rubric changes from editor events", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{rubric: "Old text"})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_hook(view, "rubric_change", %{"body" => "## Updated rubric\n\n- [ ] done"})

      assert Loops.get_loop!(loop.id).rubric == "## Updated rubric\n\n- [ ] done"
    end

    test "labels non-terminal checker result as checker verdict", %{
      conn: conn,
      workspace: workspace
    } do
      loop =
        build_task_loop!(workspace, %{
          status: :running,
          current_attempt: 1,
          max_attempts: 3
        })

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")
      send(view.pid, {:loop_history_updated, checker_verdict_history_fixture("fail")})

      html = render(view)
      assert html =~ "Checker Verdict"
      refute html =~ "Final Verdict"
    end

    test "labels terminal outcome as final verdict", %{conn: conn, workspace: workspace} do
      loop =
        build_task_loop!(workspace, %{
          status: :failed,
          current_attempt: 3,
          max_attempts: 3
        })

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")
      send(view.pid, {:loop_history_updated, checker_verdict_history_fixture("fail")})

      assert render(view) =~ "Final Verdict"
    end
  end

  defp step_history_fixture do
    [
      %{
        id: "step-maker-1",
        role: "maker",
        attempt: 1,
        status: "completed"
      },
      %{
        id: "step-checker-1",
        role: "checker",
        attempt: 1,
        status: "running"
      }
    ]
  end

  defp maker_running_history_fixture do
    [
      %{
        id: "step-maker-1",
        role: "maker",
        attempt: 1,
        status: "running",
        started_at: ~U[2026-01-01 00:01:00Z]
      }
    ]
  end

  defp out_of_order_running_checker_history_fixture do
    [
      %{
        id: "step-checker-1",
        role: "checker",
        attempt: 1,
        status: "running",
        started_at: ~U[2026-01-01 00:02:00Z]
      },
      %{
        id: "step-maker-1",
        role: "maker",
        attempt: 1,
        status: "completed",
        started_at: ~U[2026-01-01 00:01:00Z]
      }
    ]
  end

  defp no_running_checker_current_history_fixture do
    [
      %{
        id: "step-maker-1",
        role: "maker",
        attempt: 1,
        status: "completed",
        started_at: ~U[2026-01-01 00:01:00Z]
      },
      %{
        id: "step-checker-1",
        role: "checker",
        attempt: 1,
        status: "completed",
        started_at: ~U[2026-01-01 00:02:00Z]
      }
    ]
  end

  defp older_selected_running_current_history_fixture do
    [
      %{
        id: "step-maker-1",
        role: "maker",
        attempt: 1,
        status: "completed",
        started_at: ~U[2026-01-01 00:01:00Z]
      },
      %{
        id: "step-checker-1",
        role: "checker",
        attempt: 1,
        status: "completed",
        started_at: ~U[2026-01-01 00:02:00Z]
      },
      %{
        id: "step-maker-2",
        role: "maker",
        attempt: 2,
        status: "completed",
        started_at: ~U[2026-01-01 00:03:00Z]
      },
      %{
        id: "step-checker-2",
        role: "checker",
        attempt: 2,
        status: "running",
        started_at: ~U[2026-01-01 00:04:00Z]
      }
    ]
  end

  defp newer_running_checker_history_fixture do
    [
      %{
        id: "step-maker-1",
        role: "maker",
        attempt: 1,
        status: "completed",
        started_at: ~U[2026-01-01 00:01:00Z]
      },
      %{
        id: "step-checker-1",
        role: "checker",
        attempt: 1,
        status: "completed",
        started_at: ~U[2026-01-01 00:02:00Z]
      },
      %{
        id: "step-maker-2",
        role: "maker",
        attempt: 2,
        status: "completed",
        started_at: ~U[2026-01-01 00:03:00Z]
      },
      %{
        id: "step-checker-2",
        role: "checker",
        attempt: 2,
        status: "completed",
        started_at: ~U[2026-01-01 00:04:00Z]
      },
      %{
        id: "step-maker-3",
        role: "maker",
        attempt: 3,
        status: "completed",
        started_at: ~U[2026-01-01 00:05:00Z]
      },
      %{
        id: "step-checker-3",
        role: "checker",
        attempt: 3,
        status: "running",
        started_at: ~U[2026-01-01 00:06:00Z]
      }
    ]
  end

  defp checker_verdict_history_fixture(verdict) do
    [
      %{
        id: "step-maker-1",
        role: "maker",
        attempt: 1,
        status: "completed",
        started_at: ~U[2026-01-01 00:01:00Z]
      },
      %{
        id: "step-checker-1",
        role: "checker",
        attempt: 1,
        status: "completed",
        verdict: verdict,
        feedback: "Checker feedback",
        started_at: ~U[2026-01-01 00:02:00Z]
      }
    ]
  end

  describe "Diff tab" do
    test "switches to diff tab and renders diff content area", %{
      conn: conn,
      workspace: workspace
    } do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))
      html = render(view)

      assert html =~ "Changes"
      assert html =~ "Refresh"
      assert has_element?(view, "#diff-tab-content")
    end

    test "shows empty state when no daemon connected", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))

      # Trigger the debounce so fetch_diff runs and finds no daemon
      send(view.pid, :diff_debounce_fire)
      html = render(view)

      assert html =~ "No daemon connected" or html =~ "Loop has not started yet" or
               html =~ "No diff available"
    end

    test "renders diff content when diff_result arrives", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{status: :running, current_attempt: 1})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))

      diff_text = """
      diff --git a/lib/app.ex b/lib/app.ex
      index abc1234..def5678 100644
      --- a/lib/app.ex
      +++ b/lib/app.ex
      @@ -10,3 +10,4 @@ defmodule App do
         def start do
      +    Logger.info("starting")
           :ok
         end
      """

      send(view.pid, {:diff_result, diff_text, nil})
      html = render(view)

      assert html =~ "lib/app.ex"
      assert html =~ "Logger.info"
    end

    test "renders diff error state", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))
      send(view.pid, {:diff_result, nil, "Daemon timed out"})

      html = render(view)
      assert html =~ "Daemon timed out"
    end

    test "opens inline comment form on gutter click", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))

      diff_text = """
      diff --git a/lib/app.ex b/lib/app.ex
      index abc1234..def5678 100644
      --- a/lib/app.ex
      +++ b/lib/app.ex
      @@ -10,3 +10,4 @@ defmodule App do
         def start do
      +    Logger.info("starting")
           :ok
         end
      """

      send(view.pid, {:diff_result, diff_text, nil})
      render(view)

      render_click(view, "open_inline_comment", %{
        "file_path" => "lib/app.ex",
        "line_number" => "11",
        "line_type" => "addition"
      })

      html = render(view)
      assert html =~ "Write your review comment"
      assert has_element?(view, "form[phx-submit='add_inline_comment']")
    end

    test "closes inline comment form", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))
      send(view.pid, {:diff_result, sample_diff(), nil})
      render(view)

      render_click(view, "open_inline_comment", %{
        "file_path" => "lib/app.ex",
        "line_number" => "11",
        "line_type" => "addition"
      })

      assert render(view) =~ "Write your review comment"

      render_click(view, "close_inline_comment")
      refute render(view) =~ "Write your review comment"
    end

    test "submits inline comment and creates review", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))
      send(view.pid, {:diff_result, sample_diff(), nil})
      render(view)

      render_click(view, "open_inline_comment", %{
        "file_path" => "lib/app.ex",
        "line_number" => "11",
        "line_type" => "addition"
      })

      render_submit(view, "add_inline_comment", %{
        "file_path" => "lib/app.ex",
        "line_number" => "11",
        "body" => "This needs error handling."
      })

      reviews = Algedonia.InlineReviews.list_by_loop(loop.id)
      assert length(reviews) == 1
      assert hd(reviews).body == "This needs error handling."
      assert hd(reviews).file_path == "lib/app.ex"
      assert hd(reviews).line_number == 11
    end

    test "displays existing inline reviews on diff lines", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})

      {:ok, _review} =
        Algedonia.InlineReviews.create(%{
          loop_id: loop.id,
          author: "ada",
          file_path: "lib/app.ex",
          line_number: 11,
          diff_hunk: "+    Logger.info(\"starting\")",
          body: "Good addition."
        })

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))
      send(view.pid, {:diff_result, sample_diff(), nil})
      html = render(view)

      assert html =~ "Good addition."
      assert html =~ "ada"
    end

    test "poll_diff is a no-op when tab is not diff", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      # Stay on overview tab, send poll_diff — should be a no-op, no crash
      send(view.pid, :poll_diff)
      assert render(view) =~ "Overview"
    end

    test "poll_diff handles diff tab without crashing", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))
      send(view.pid, {:diff_result, sample_diff(), nil})
      render(view)

      # Send poll_diff while on diff tab — should not crash
      send(view.pid, :poll_diff)
      assert render(view) =~ "lib/app.ex"
    end

    test "switching away from diff tab cancels timers", %{conn: conn, workspace: workspace} do
      loop = build_task_loop!(workspace, %{})
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")

      render_click(element(view, "button[phx-value-tab='diff']"))
      send(view.pid, {:diff_result, sample_diff(), nil})
      render(view)

      # Switch away from diff tab
      render_click(element(view, "button[phx-value-tab='overview']"))

      # poll_diff should be a no-op now (doesn't crash, doesn't fetch)
      send(view.pid, :poll_diff)
      html = render(view)
      refute html =~ "Changes"
    end
  end

  defp sample_diff do
    """
    diff --git a/lib/app.ex b/lib/app.ex
    index abc1234..def5678 100644
    --- a/lib/app.ex
    +++ b/lib/app.ex
    @@ -10,3 +10,4 @@ defmodule App do
       def start do
    +    Logger.info("starting")
         :ok
       end
    """
  end

  defp build_task_loop!(workspace, overrides) do
    ticket = Factory.insert_ticket!(%{workspace_id: workspace.id})
    Factory.insert_loop!(Map.merge(%{ticket_id: ticket.id, role: :task}, overrides))
  end
end
