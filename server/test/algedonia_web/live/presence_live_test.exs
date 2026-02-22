defmodule AlgedoniaWeb.PresenceLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "two users on /tickets see each other", %{conn: conn} do
    conn1 = Plug.Test.init_test_session(conn, %{display_name: "Ada"})
    conn2 = Plug.Test.init_test_session(conn, %{display_name: "Bob"})

    {:ok, view1, _html} = live(conn1, ~p"/tickets")
    {:ok, _view2, _html} = live(conn2, ~p"/tickets")

    # Give presence time to propagate
    Process.sleep(100)

    html = render(view1)
    assert html =~ "Bob"
    assert html =~ "also viewing"
  end

  test "disconnecting removes presence", %{conn: conn} do
    conn1 = Plug.Test.init_test_session(conn, %{display_name: "Ada"})
    conn2 = Plug.Test.init_test_session(conn, %{display_name: "Bob"})

    {:ok, view1, _html} = live(conn1, ~p"/tickets")
    {:ok, view2, _html} = live(conn2, ~p"/tickets")

    Process.sleep(100)
    assert render(view1) =~ "Bob"

    # Disconnect Bob
    GenServer.stop(view2.pid)
    Process.sleep(100)

    refute render(view1) =~ "also viewing"
  end

  test "users on /tickets don't see users on /monitor", %{conn: conn} do
    conn1 = Plug.Test.init_test_session(conn, %{display_name: "Ada"})
    conn2 = Plug.Test.init_test_session(conn, %{display_name: "Bob"})

    {:ok, view1, _html} = live(conn1, ~p"/tickets")
    {:ok, _view2, _html} = live(conn2, ~p"/monitor")

    Process.sleep(100)

    refute render(view1) =~ "Bob"
  end
end
