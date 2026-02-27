defmodule AlgedoniaWeb.LoopLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Algedonia.{Factory, Loops, Terminals}

  describe "Show" do
    test "mounts and renders loop_id", %{conn: conn, workspace: workspace} do
      {:ok, view, html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/test-loop-1")

      assert html =~ "test-loop-1"
      assert has_element?(view, "[id^=terminal-attempt-]")
    end

    test "shows start button when inactive", %{conn: conn, workspace: workspace} do
      {:ok, view, html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/test-loop-new")

      assert html =~ "Start Loop"
      refute html =~ "Stop Loop"
      assert has_element?(view, "#loop-index-badge")
    end

    test "renders split panel shell with resize handle and persistence wiring", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/test-loop-resize")

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
      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/test-loop-layout-contract")

      refute has_element?(view, "#loop-workspace-layout[style*='--left-sidebar-width']")
      refute has_element?(view, "#loop-inspector-layout[style*='--inspector-width']")

      assert has_element?(view, "#loop-workspace-layout[phx-hook='SidebarPanel']")
      assert has_element?(view, "#loop-workspace-layout [data-sidebar-toggle]")
      assert has_element?(view, "#loop-workspace-layout[data-collapsed-width='52']")
      assert has_element?(view, "#loop-inspector-layout[phx-hook='SplitPanel']")
    end

    test "sends scrollback on connect when buffer exists", %{conn: conn, workspace: workspace} do
      loop_id = "scrollback-test-#{System.unique_integer([:positive])}"
      Terminals.append(loop_id, "prior output")

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      # The scrollback is sent as a push_event
      assert render(view) =~ loop_id
    end

    test "receives PubSub terminal data updates", %{conn: conn, workspace: workspace} do
      loop_id = "pubsub-test-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      # Simulate terminal data arriving via PubSub
      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        "terminal:#{loop_id}",
        {:terminal_data, loop_id, "new output"}
      )

      # The LiveView should handle it without crashing
      assert render(view) =~ loop_id
    end

    test "handles terminal data bursts without crashing", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "coalesce-test-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        "terminal:#{loop_id}",
        {:terminal_data, loop_id, "foo"}
      )

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        "terminal:#{loop_id}",
        {:terminal_data, loop_id, "bar"}
      )

      assert render(view) =~ loop_id
    end

    test "handles terminal_ended event", %{conn: conn, workspace: workspace} do
      loop_id = "ended-test-#{System.unique_integer([:positive])}"
      Terminals.start_buffer(loop_id)

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        "terminal:#{loop_id}",
        {:terminal_data, loop_id, "tail output"}
      )

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        "terminal:#{loop_id}",
        {:terminal_ended, loop_id, 0}
      )

      assert_push_event(view, "terminal_ended", %{exit_code: 0})

      html = render(view)
      assert html =~ "Inactive"
    end

    test "does not render history sidebar tab and toggles steps panel", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/test-loop-steps")

      refute html =~ "History"

      refute has_element?(view, "button[phx-click='select_step']")
      render_click(element(view, "button[phx-click='toggle_steps']"))
      assert render(view) =~ "No maker/checker runs yet."
    end

    test "renders step tabs and switches terminal label when selecting a step", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "history-tabs-#{System.unique_integer([:positive])}"
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

    test "orders out-of-order history and marks checker as current when running", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "history-order-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop_id}")

      send(view.pid, {:loop_history_updated, out_of_order_running_checker_history_fixture()})

      render_click(element(view, "button[phx-click='toggle_steps']"))
      html = render(view)

      assert has_element?(view, "button[phx-value-step_id='step-checker-1'] .animate-spin")
      assert has_element?(view, "#attempt-1-checker-step-checker-1")
      assert html =~ ~r/Maker #1.*Checker #1/s
    end

    test "uses loop status as current step when no history entry is running", %{
      conn: conn,
      workspace: workspace
    } do
      loop =
        build_task_loop!(workspace, %{
          status: :running_checker,
          current_attempt: 1
        })

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")
      send(view.pid, {:loop_history_updated, no_running_checker_current_history_fixture()})

      render_click(element(view, "button[phx-click='toggle_steps']"))

      assert has_element?(view, "button[phx-value-step_id='step-checker-1'] .animate-spin")
      assert has_element?(view, "#attempt-1-checker-step-checker-1")
    end

    test "keeps current spinner on running step while viewing older step", %{
      conn: conn,
      workspace: workspace
    } do
      loop =
        build_task_loop!(workspace, %{
          status: :running_checker,
          current_attempt: 2
        })

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/tickets/test-ticket/loops/#{loop.id}")
      send(view.pid, {:loop_history_updated, older_selected_running_current_history_fixture()})

      render_click(element(view, "button[phx-click='toggle_steps']"))
      render_click(element(view, "button[phx-value-step_id='step-maker-1']"))

      assert has_element?(view, "#attempt-1-maker-step-maker-1")
      assert has_element?(view, "button[phx-value-step_id='step-checker-2'] .animate-spin")
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
      {:ok, view, _html} =
        live(conn, ~p"/w/#{workspace.slug}/tickets/test-ticket/loops/test-loop-shortcuts")

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
          status: :running_checker,
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

  defp build_task_loop!(workspace, overrides) do
    ticket = Factory.insert_ticket!(%{workspace_id: workspace.id})
    dag = Factory.insert_dag!(%{ticket_id: ticket.id})
    Factory.insert_loop!(Map.merge(%{dag_id: dag.id, role: :task}, overrides))
  end
end
