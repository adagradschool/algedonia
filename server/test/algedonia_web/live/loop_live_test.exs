defmodule AlgedoniaWeb.LoopLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Algedonia.Terminals

  describe "Show" do
    test "mounts and renders loop_id", %{conn: conn, workspace: workspace} do
      {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/loops/test-loop-1")
      assert html =~ "test-loop-1"
      assert has_element?(view, "[id^=terminal-attempt-]")
    end

    test "shows start button when inactive", %{conn: conn, workspace: workspace} do
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/loops/test-loop-new")
      assert html =~ "Start Loop"
      refute html =~ "Stop Loop"
    end

    test "sends scrollback on connect when buffer exists", %{conn: conn, workspace: workspace} do
      loop_id = "scrollback-test-#{System.unique_integer([:positive])}"
      Terminals.append(loop_id, "prior output")

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/loops/#{loop_id}")

      # The scrollback is sent as a push_event
      assert render(view) =~ loop_id
    end

    test "receives PubSub terminal data updates", %{conn: conn, workspace: workspace} do
      loop_id = "pubsub-test-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/loops/#{loop_id}")

      # Simulate terminal data arriving via PubSub
      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        "terminal:#{loop_id}",
        {:terminal_data, loop_id, "new output"}
      )

      # The LiveView should handle it without crashing
      assert render(view) =~ loop_id
    end

    test "coalesces terminal data bursts into one pushed chunk", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "coalesce-test-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/loops/#{loop_id}")

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

      expected = Base.encode64("foobar")
      assert_push_event(view, "terminal_data", %{data: ^expected})
    end

    test "terminal_input event is a graceful no-op without online daemon", %{
      conn: conn,
      workspace: workspace
    } do
      loop_id = "stdin-test-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/loops/#{loop_id}")

      # Should not crash even with no online daemon
      render_hook(view, "terminal_input", %{"data" => Base.encode64("hello")})
      assert render(view) =~ loop_id
    end

    test "handles terminal_ended event", %{conn: conn, workspace: workspace} do
      loop_id = "ended-test-#{System.unique_integer([:positive])}"
      Terminals.start_buffer(loop_id)

      {:ok, view, _html} = live(conn, "/w/#{workspace.slug}/loops/#{loop_id}")

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

      expected = Base.encode64("tail output")
      assert_push_event(view, "terminal_data", %{data: ^expected})
      assert_push_event(view, "terminal_ended", %{exit_code: 0})

      html = render(view)
      assert html =~ "Inactive"
    end
  end
end
