defmodule AlgedoniaWeb.Plugs.ApiAuthTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias AlgedoniaWeb.Plugs.ApiAuth

  describe "call/2" do
    test "assigns current_user with valid token", %{user: user} do
      token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> ApiAuth.call([])

      assert conn.assigns.current_user.id == user.id
      refute conn.halted
    end

    test "halts with 401 when no authorization header" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "halts with 401 for invalid token" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer invalid-token-garbage")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "halts with 401 for malformed authorization header" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "NotBearer something")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "halts with 401 when user no longer exists" do
      # Sign a token for a user ID that doesn't exist (users use bigserial IDs)
      token =
        Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{
          user_id: 999_999_999
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end
end
