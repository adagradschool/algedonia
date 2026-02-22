defmodule AlgedoniaWeb.PresenceLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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
