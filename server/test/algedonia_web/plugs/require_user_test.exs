defmodule AlgedoniaWeb.Plugs.RequireUserTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias AlgedoniaWeb.Plugs.RequireUser

  describe "call/2" do
    test "redirects to / with flash when no user_id in session" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> init_flash()
        |> RequireUser.call([])

      assert conn.halted
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "sign in"
    end

    test "drops session and redirects when user_id does not exist in DB" do
      fake_id = Ecto.UUID.generate()

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{user_id: fake_id})
        |> init_flash()
        |> RequireUser.call([])

      assert conn.halted
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "sign in"
    end

    test "assigns current_user when valid user exists in session", %{user: user} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> init_flash()
        |> RequireUser.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end
  end

  defp init_flash(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Plug.Conn.put_private(:phoenix_endpoint, AlgedoniaWeb.Endpoint)
    |> Plug.Conn.put_private(:phoenix_router, AlgedoniaWeb.Router)
    |> Plug.Conn.put_private(:phoenix_flash, %{})
    |> Phoenix.Controller.fetch_flash([])
  end
end
