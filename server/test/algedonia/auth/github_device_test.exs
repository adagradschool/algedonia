defmodule Algedonia.Auth.GithubDeviceTest do
  use ExUnit.Case, async: true

  alias Algedonia.Auth.GithubDevice

  describe "request_device_code/0" do
    test "returns device code struct on success" do
      Req.Test.stub(GithubDevice, fn conn ->
        Req.Test.json(conn, %{
          "device_code" => "dc_abc123",
          "user_code" => "ABCD-1234",
          "verification_uri" => "https://github.com/login/device",
          "expires_in" => 900,
          "interval" => 5
        })
      end)

      assert {:ok, result} = GithubDevice.request_device_code()
      assert result.device_code == "dc_abc123"
      assert result.user_code == "ABCD-1234"
      assert result.verification_uri == "https://github.com/login/device"
      assert result.expires_in == 900
      assert result.interval == 5
    end

    test "returns error on non-200 response" do
      Req.Test.stub(GithubDevice, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"error" => "bad_request"})
      end)

      assert {:error, message} = GithubDevice.request_device_code()
      assert message =~ "422"
    end
  end

  describe "poll_for_token/1" do
    test "returns token on success" do
      Req.Test.stub(GithubDevice, fn conn ->
        Req.Test.json(conn, %{"access_token" => "gho_secrettoken123"})
      end)

      assert {:ok, "gho_secrettoken123"} = GithubDevice.poll_for_token("dc_abc123")
    end

    test "returns pending on authorization_pending" do
      Req.Test.stub(GithubDevice, fn conn ->
        Req.Test.json(conn, %{"error" => "authorization_pending"})
      end)

      assert {:pending, "authorization_pending"} = GithubDevice.poll_for_token("dc_abc123")
    end

    test "returns pending on slow_down" do
      Req.Test.stub(GithubDevice, fn conn ->
        Req.Test.json(conn, %{"error" => "slow_down"})
      end)

      assert {:pending, "slow_down"} = GithubDevice.poll_for_token("dc_abc123")
    end

    test "returns error on other error responses" do
      Req.Test.stub(GithubDevice, fn conn ->
        Req.Test.json(conn, %{"error" => "expired_token"})
      end)

      assert {:error, "expired_token"} = GithubDevice.poll_for_token("dc_abc123")
    end

    test "returns error on non-200 status" do
      Req.Test.stub(GithubDevice, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "server error"})
      end)

      assert {:error, message} = GithubDevice.poll_for_token("dc_abc123")
      assert message =~ "500"
    end
  end

  describe "get_user_info/1" do
    test "returns normalized user profile on success" do
      Req.Test.stub(GithubDevice, fn conn ->
        Req.Test.json(conn, %{
          "id" => 12_345,
          "login" => "octocat",
          "name" => "The Octocat",
          "email" => "octocat@github.com",
          "avatar_url" => "https://avatars.githubusercontent.com/u/12_345"
        })
      end)

      assert {:ok, profile} = GithubDevice.get_user_info("gho_token")
      assert profile.github_id == 12_345
      assert profile.github_username == "octocat"
      assert profile.name == "The Octocat"
      assert profile.email == "octocat@github.com"
      assert profile.avatar_url == "https://avatars.githubusercontent.com/u/12_345"
    end

    test "falls back to login when name is nil" do
      Req.Test.stub(GithubDevice, fn conn ->
        Req.Test.json(conn, %{
          "id" => 12_345,
          "login" => "octocat",
          "name" => nil,
          "email" => nil,
          "avatar_url" => nil
        })
      end)

      assert {:ok, profile} = GithubDevice.get_user_info("gho_token")
      assert profile.name == "octocat"
    end

    test "returns error on unauthorized response" do
      Req.Test.stub(GithubDevice, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "Bad credentials"})
      end)

      assert {:error, message} = GithubDevice.get_user_info("bad_token")
      assert message =~ "401"
    end
  end
end
