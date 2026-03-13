defmodule AlgedoniaWeb.PresenceLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Algedonia.Factory
  alias Algedonia.PubSub.Topics

  test "two users on /tickets see each other", %{conn: conn, workspace: workspace, user: user} do
    conn1 =
      Plug.Test.init_test_session(conn, %{
        display_name: "Ada",
        user_id: user.id,
        current_workspace_id: workspace.id,
        current_workspace_slug: workspace.slug,
        current_workspace_prefix: workspace.prefix
      })

    conn2 =
      Plug.Test.init_test_session(conn, %{
        display_name: "Bob",
        user_id: user.id,
        current_workspace_id: workspace.id,
        current_workspace_slug: workspace.slug,
        current_workspace_prefix: workspace.prefix
      })

    {:ok, view1, _html} = live(conn1, ~p"/w/#{workspace.slug}/tickets")
    {:ok, _view2, _html} = live(conn2, ~p"/w/#{workspace.slug}/tickets")

    assert_eventually(fn -> render(view1) =~ "Bob" end)
    assert render(view1) =~ "also viewing"
  end

  test "disconnecting removes presence", %{conn: conn, workspace: workspace, user: user} do
    conn1 =
      Plug.Test.init_test_session(conn, %{
        display_name: "Ada",
        user_id: user.id,
        current_workspace_id: workspace.id,
        current_workspace_slug: workspace.slug,
        current_workspace_prefix: workspace.prefix
      })

    conn2 =
      Plug.Test.init_test_session(conn, %{
        display_name: "Bob",
        user_id: user.id,
        current_workspace_id: workspace.id,
        current_workspace_slug: workspace.slug,
        current_workspace_prefix: workspace.prefix
      })

    {:ok, view1, _html} = live(conn1, ~p"/w/#{workspace.slug}/tickets")
    {:ok, view2, _html} = live(conn2, ~p"/w/#{workspace.slug}/tickets")

    assert_eventually(fn -> render(view1) =~ "Bob" end)

    GenServer.stop(view2.pid)

    assert_eventually(fn -> not (render(view1) =~ "also viewing") end)
  end

  test "users on /tickets don't see users on /monitor", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    conn1 =
      Plug.Test.init_test_session(conn, %{
        display_name: "Ada",
        user_id: user.id,
        current_workspace_id: workspace.id,
        current_workspace_slug: workspace.slug,
        current_workspace_prefix: workspace.prefix
      })

    conn2 =
      Plug.Test.init_test_session(conn, %{
        display_name: "Bob",
        user_id: user.id,
        current_workspace_id: workspace.id,
        current_workspace_slug: workspace.slug,
        current_workspace_prefix: workspace.prefix
      })

    {:ok, view1, _html} = live(conn1, ~p"/w/#{workspace.slug}/tickets")
    {:ok, _view2, _html} = live(conn2, ~p"/w/#{workspace.slug}/monitor")

    # Wait for presence to settle, then verify isolation
    Process.sleep(200)
    refute render(view1) =~ "Bob"
  end

  test "url workspace slug takes precedence over stale session workspace", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    target_workspace =
      Algedonia.Factory.insert_workspace!(%{name: "Target Workspace", slug: "target-workspace"})

    Algedonia.Factory.insert_membership!(target_workspace, user)

    stale_conn =
      Plug.Test.init_test_session(conn, %{
        display_name: "Ada",
        user_id: user.id,
        current_workspace_id: workspace.id,
        current_workspace_slug: workspace.slug,
        current_workspace_prefix: workspace.prefix
      })

    {:ok, view, _html} = live(stale_conn, ~p"/w/#{target_workspace.slug}/tickets")

    assert has_element?(
             view,
             "#global-command-palette[data-tickets-path='/w/#{target_workspace.slug}/tickets']"
           )
  end

  test "tickets layout avatar badge updates for daemon status transitions", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    daemon =
      Factory.insert_daemon!(%{
        name: "badge-daemon",
        user_id: user.id,
        status: :offline
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/tickets")

    assert has_element?(view, ~s([data-testid="workspace-daemon-badge"][data-state="offline"]))

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.monitor(workspace.id),
      {:daemon_status_changed, %{daemon | status: :unhealthy}}
    )

    assert_eventually(fn ->
      has_element?(view, ~s([data-testid="workspace-daemon-badge"][data-state="unhealthy"]))
    end)

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.monitor(workspace.id),
      {:daemon_status_changed, %{daemon | status: :online}}
    )

    assert_eventually(fn ->
      has_element?(view, ~s([data-testid="workspace-daemon-badge"][data-state="online"]))
    end)
  end

  test "home layout avatar badge defaults to offline and updates for daemon status transitions",
       %{
         conn: conn,
         workspace: workspace,
         user: user
       } do
    daemon =
      Factory.insert_daemon!(%{
        name: "home-badge-daemon",
        user_id: user.id,
        status: :offline
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}")

    assert has_element?(view, ~s([data-testid="workspace-daemon-badge"][data-state="offline"]))

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.monitor(workspace.id),
      {:daemon_status_changed, %{daemon | status: :unhealthy}}
    )

    assert_eventually(fn ->
      has_element?(view, ~s([data-testid="workspace-daemon-badge"][data-state="unhealthy"]))
    end)

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.monitor(workspace.id),
      {:daemon_status_changed, %{daemon | status: :online}}
    )

    assert_eventually(fn ->
      has_element?(view, ~s([data-testid="workspace-daemon-badge"][data-state="online"]))
    end)
  end

  defp assert_eventually(func, attempts \\ 50) do
    if func.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(50)
        assert_eventually(func, attempts - 1)
      else
        flunk("Condition was not met after retries")
      end
    end
  end
end
