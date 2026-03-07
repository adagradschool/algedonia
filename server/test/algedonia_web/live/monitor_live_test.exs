defmodule AlgedoniaWeb.MonitorLiveTest do
  use AlgedoniaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Algedonia.Factory
  alias Algedonia.PubSub.Topics

  describe "index" do
    test "renders daemon monitor page", %{conn: conn, workspace: workspace} do
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/monitor")
      assert html =~ "Daemon Monitor"
    end

    test "displays registered daemons", %{conn: conn, workspace: workspace, user: user} do
      Factory.insert_daemon!(%{name: "my-daemon", display_name: "My Daemon", user_id: user.id})

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/monitor")
      assert html =~ "My Daemon"
    end

    test "updates on daemon status change", %{conn: conn, workspace: workspace, user: user} do
      daemon =
        Factory.insert_daemon!(%{
          name: "live-daemon",
          display_name: "Live Daemon",
          user_id: user.id
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/monitor")

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.monitor(workspace.id),
        {:daemon_status_changed, %{daemon | status: :unhealthy}}
      )

      html = render(view)
      assert html =~ "unhealthy"
    end

    test "updates on daemon heartbeat", %{conn: conn, workspace: workspace, user: user} do
      daemon =
        Factory.insert_daemon!(%{
          name: "hb-daemon",
          display_name: "HB Daemon",
          capacity: 3,
          user_id: user.id
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/monitor")

      Phoenix.PubSub.broadcast(
        Algedonia.PubSub,
        Topics.monitor(workspace.id),
        {:daemon_heartbeat, %{daemon | capacity: 10}}
      )

      html = render(view)
      assert html =~ "10"
    end
  end
end
