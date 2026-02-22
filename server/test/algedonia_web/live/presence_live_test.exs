defmodule AlgedoniaWeb.PresenceLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "two users on /tickets see each other", %{conn: conn} do
    conn1 = Plug.Test.init_test_session(conn, %{display_name: "Ada"})
    conn2 = Plug.Test.init_test_session(conn, %{display_name: "Bob"})

    {:ok, view1, _html} = live(conn1, ~p"/tickets")
    {:ok, _view2, _html} = live(conn2, ~p"/tickets")

    assert_eventually(fn -> render(view1) =~ "Bob" end)
    assert render(view1) =~ "also viewing"
  end

  test "disconnecting removes presence", %{conn: conn} do
    conn1 = Plug.Test.init_test_session(conn, %{display_name: "Ada"})
    conn2 = Plug.Test.init_test_session(conn, %{display_name: "Bob"})

    {:ok, view1, _html} = live(conn1, ~p"/tickets")
    {:ok, view2, _html} = live(conn2, ~p"/tickets")

    assert_eventually(fn -> render(view1) =~ "Bob" end)

    GenServer.stop(view2.pid)

    assert_eventually(fn -> not (render(view1) =~ "also viewing") end)
  end

  test "users on /tickets don't see users on /monitor", %{conn: conn} do
    conn1 = Plug.Test.init_test_session(conn, %{display_name: "Ada"})
    conn2 = Plug.Test.init_test_session(conn, %{display_name: "Bob"})

    {:ok, view1, _html} = live(conn1, ~p"/tickets")
    {:ok, _view2, _html} = live(conn2, ~p"/monitor")

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
