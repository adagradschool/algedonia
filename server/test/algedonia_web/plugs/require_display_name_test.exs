defmodule AlgedoniaWeb.Plugs.RequireDisplayNameTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias AlgedoniaWeb.Plugs.RequireDisplayName

  test "passes through when display_name is set", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{display_name: "Ada"})
      |> RequireDisplayName.call([])

    refute conn.halted
  end

  test "redirects when display_name is missing" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> fetch_flash()
      |> RequireDisplayName.call([])

    assert conn.halted
    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "ag connect"
  end
end
