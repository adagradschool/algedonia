defmodule Algedonia.Auth.SupabaseTest do
  use ExUnit.Case, async: true

  alias Algedonia.Auth.Supabase

  describe "authorize_url/0" do
    test "returns a valid Supabase URL and code verifier" do
      config = Application.fetch_env!(:algedonia, :supabase)
      expected_host = URI.parse(Keyword.fetch!(config, :project_url)).host
      expected_callback = Keyword.fetch!(config, :gh_auth_callback)

      {url, code_verifier} = Supabase.authorize_url()

      uri = URI.parse(url)
      assert uri.host == expected_host
      assert uri.path == "/auth/v1/authorize"

      params = URI.decode_query(uri.query)
      assert params["provider"] == "github"
      assert params["flow_type"] == "pkce"
      assert params["code_challenge_method"] == "S256"
      assert params["redirect_to"] == expected_callback
      assert is_binary(params["code_challenge"])
      assert byte_size(params["code_challenge"]) > 0

      # Verifier should be base64url-encoded 32 bytes = 43 chars
      assert byte_size(code_verifier) >= 43
      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, code_verifier)
    end
  end

  describe "exchange_code_for_user/2" do
    test "extracts GitHub profile from successful response" do
      Req.Test.stub(Supabase, fn conn ->
        Req.Test.json(conn, %{
          "user" => %{
            "email" => "octo@github.com",
            "identities" => [
              %{"provider" => "github", "provider_id" => "99887"}
            ],
            "user_metadata" => %{
              "user_name" => "octocat",
              "full_name" => "The Octocat",
              "avatar_url" => "https://example.com/avatar.png"
            }
          }
        })
      end)

      assert {:ok, profile} = Supabase.exchange_code_for_user("auth_code", "verifier")
      assert profile.github_id == 99_887
      assert profile.github_username == "octocat"
      assert profile.name == "The Octocat"
      assert profile.email == "octo@github.com"
      assert profile.avatar_url == "https://example.com/avatar.png"
    end

    test "returns error when no GitHub identity found" do
      Req.Test.stub(Supabase, fn conn ->
        Req.Test.json(conn, %{
          "user" => %{
            "email" => "user@example.com",
            "identities" => [
              %{"provider" => "google", "provider_id" => "12_345"}
            ],
            "user_metadata" => %{}
          }
        })
      end)

      assert {:error, message} = Supabase.exchange_code_for_user("auth_code", "verifier")
      assert message =~ "No GitHub identity"
    end

    test "returns error on HTTP failure" do
      Req.Test.stub(Supabase, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, message} = Supabase.exchange_code_for_user("bad_code", "verifier")
      assert message =~ "400"
    end
  end
end
