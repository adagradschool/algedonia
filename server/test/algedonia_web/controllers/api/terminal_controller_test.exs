defmodule AlgedoniaWeb.Api.TerminalControllerTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias AlgedoniaWeb.TerminalAccessToken

  setup %{user: user} do
    daemon_token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})

    conn =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer #{daemon_token}")
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  describe "POST /api/terminal/verify" do
    test "returns ok for valid token and matching loop_id", %{conn: conn, user: user} do
      loop_id = Ecto.UUID.generate()
      token = TerminalAccessToken.sign(user.id, loop_id)

      conn =
        post(conn, "/api/terminal/verify", %{
          "token" => token,
          "loop_id" => loop_id
        })

      assert %{"ok" => true} = json_response(conn, 200)
    end

    test "returns unauthorized when loop_id mismatches", %{conn: conn, user: user} do
      token = TerminalAccessToken.sign(user.id, Ecto.UUID.generate())

      conn =
        post(conn, "/api/terminal/verify", %{
          "token" => token,
          "loop_id" => Ecto.UUID.generate()
        })

      assert %{"error" => "invalid_terminal_token"} = json_response(conn, 401)
    end
  end
end
