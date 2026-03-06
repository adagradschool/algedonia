defmodule AlgedoniaWeb.AuthControllerTest do
  use AlgedoniaWeb.ConnCase, async: true
  import Ecto.Query

  alias Algedonia.Accounts.User
  alias Algedonia.Auth.{GithubDevice, Supabase}
  alias Algedonia.Repo

  test "GET /auth/github redirects to Supabase OAuth", %{conn: conn} do
    conn = get(conn, ~p"/auth/github")
    location = redirected_to(conn)
    assert location =~ "/auth/v1/authorize"
    assert location =~ "flow_type=pkce"
    assert location =~ "code_challenge="
  end

  test "GET /auth/callback without code redirects to / with flash", %{conn: conn} do
    conn = get(conn, ~p"/auth/callback")
    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing"
  end

  test "DELETE /auth/logout clears session and redirects to /", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{user_id: Ecto.UUID.generate()})
      |> delete(~p"/auth/logout")

    assert redirected_to(conn) == "/"
  end

  test "GET /auth/callback creates a user from GitHub profile" do
    Req.Test.stub(Supabase, fn conn ->
      Req.Test.json(conn, %{
        "provider_token" => "gho_provider_token",
        "user" => %{
          "email" => "octocat@github.com",
          "identities" => [%{"provider" => "github", "provider_id" => "424242"}],
          "user_metadata" => %{
            "user_name" => "octocat",
            "full_name" => "The Octocat",
            "avatar_url" => "https://avatars.githubusercontent.com/u/424242"
          }
        }
      })
    end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> init_test_session(%{pkce_code_verifier: "verifier"})
      |> get(~p"/auth/callback?code=test-code")

    assert redirected_to(conn) == "/onboarding"

    user = Repo.get_by!(User, github_id: 424_242)
    assert user.github_username == "octocat"
    assert user.name == "The Octocat"
    assert user.email == "octocat@github.com"
    assert user.avatar_url == "https://avatars.githubusercontent.com/u/424242"
  end

  test "GET /auth/callback updates existing user for same github_id", %{user: _ignored_user} do
    existing =
      Algedonia.Factory.insert_user!(%{
        github_id: 9898,
        github_username: "old-name",
        name: "Old Name",
        email: "old@example.com",
        avatar_url: "https://old.example/avatar.png"
      })

    Req.Test.stub(Supabase, fn conn ->
      Req.Test.json(conn, %{
        "provider_token" => "gho_provider_token",
        "user" => %{
          "email" => "new@example.com",
          "identities" => [%{"provider" => "github", "provider_id" => "9898"}],
          "user_metadata" => %{
            "user_name" => "new-name",
            "full_name" => "New Name",
            "avatar_url" => "https://new.example/avatar.png"
          }
        }
      })
    end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> init_test_session(%{pkce_code_verifier: "verifier"})
      |> get(~p"/auth/callback?code=test-code")

    assert redirected_to(conn) == "/onboarding"

    updated = Repo.get!(User, existing.id)
    assert updated.github_username == "new-name"
    assert updated.name == "New Name"
    assert updated.email == "new@example.com"
    assert updated.avatar_url == "https://new.example/avatar.png"

    assert Repo.aggregate(from(u in User, where: u.github_id == 9898), :count, :id) == 1
  end

  test "POST /api/auth/device/poll creates a user from GitHub profile" do
    Req.Test.stub(GithubDevice, fn conn ->
      case conn.request_path do
        "/login/oauth/access_token" ->
          Req.Test.json(conn, %{"access_token" => "gho_secrettoken"})

        "/user" ->
          Req.Test.json(conn, %{
            "id" => 56_789,
            "login" => "device-user",
            "name" => "Device User",
            "email" => "device@example.com",
            "avatar_url" => "https://avatars.githubusercontent.com/u/56789"
          })
      end
    end)

    conn =
      post(Phoenix.ConnTest.build_conn(), ~p"/api/auth/device/poll", %{device_code: "device-123"})

    assert %{"status" => "ok", "token" => token, "user" => %{"id" => user_id}} =
             json_response(conn, 200)

    assert is_binary(token)

    user = Repo.get!(User, user_id)
    assert user.github_id == 56_789
    assert user.github_username == "device-user"
    assert user.name == "Device User"
    assert user.email == "device@example.com"
    assert user.avatar_url == "https://avatars.githubusercontent.com/u/56789"
  end

  test "POST /api/auth/device/poll updates an existing user for same github_id" do
    existing =
      Algedonia.Factory.insert_user!(%{
        github_id: 77_777,
        github_username: "before-device",
        name: "Before Device",
        email: "before@example.com",
        avatar_url: "https://before.example/avatar.png"
      })

    Req.Test.stub(GithubDevice, fn conn ->
      case conn.request_path do
        "/login/oauth/access_token" ->
          Req.Test.json(conn, %{"access_token" => "gho_secrettoken"})

        "/user" ->
          Req.Test.json(conn, %{
            "id" => 77_777,
            "login" => "after-device",
            "name" => "After Device",
            "email" => "after@example.com",
            "avatar_url" => "https://after.example/avatar.png"
          })
      end
    end)

    conn =
      post(Phoenix.ConnTest.build_conn(), ~p"/api/auth/device/poll", %{device_code: "device-123"})

    assert %{"status" => "ok", "user" => %{"id" => user_id}} = json_response(conn, 200)
    assert user_id == existing.id

    updated = Repo.get!(User, existing.id)
    assert updated.github_username == "after-device"
    assert updated.name == "After Device"
    assert updated.email == "after@example.com"
    assert updated.avatar_url == "https://after.example/avatar.png"

    assert Repo.aggregate(from(u in User, where: u.github_id == 77_777), :count, :id) == 1
  end
end
