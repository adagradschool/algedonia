defmodule Algedonia.Auth.Supabase do
  @moduledoc """
  Handles Supabase GitHub OAuth using PKCE flow.
  """

  def authorize_url do
    config = Application.fetch_env!(:algedonia, :supabase)

    project_url =
      Keyword.fetch!(config, :project_url) ||
        raise "SUPABASE_PROJECT_URL is not set"

    callback =
      Keyword.fetch!(config, :gh_auth_callback) ||
        raise "SUPABASE_GH_AUTH_CALLBACK is not set"

    code_verifier = generate_code_verifier()
    code_challenge = generate_code_challenge(code_verifier)

    query =
      URI.encode_query(%{
        "provider" => "github",
        "redirect_to" => callback,
        "flow_type" => "pkce",
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      })

    url = "#{project_url}/auth/v1/authorize?#{query}"
    {url, code_verifier}
  end

  def exchange_code_for_user(code, code_verifier) do
    config = Application.fetch_env!(:algedonia, :supabase)
    project_url = Keyword.fetch!(config, :project_url)
    api_key = Keyword.fetch!(config, :publishable_key)

    url = "#{project_url}/auth/v1/token?grant_type=pkce"

    headers = [
      {"content-type", "application/json"},
      {"apikey", api_key}
    ]

    body =
      Jason.encode!(%{
        "auth_code" => code,
        "code_verifier" => code_verifier
      })

    case Req.post(url, headers: headers, body: body) do
      {:ok, %{status: 200, body: body}} ->
        extract_github_profile(body)

      {:ok, %{status: status, body: body}} ->
        {:error, "Supabase token exchange failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Supabase request failed: #{inspect(reason)}"}
    end
  end

  defp extract_github_profile(%{"user" => user}) do
    meta = user["user_metadata"] || %{}
    github_id = find_github_id(user, meta)

    case github_id do
      nil ->
        {:error, "No GitHub identity found in Supabase response"}

      id ->
        {:ok, build_profile(id, user, meta)}
    end
  end

  defp extract_github_profile(_body), do: {:error, "Unexpected Supabase response format"}

  defp find_github_id(user, meta) do
    identities = user["identities"] || []
    github_identity = Enum.find(identities, &(&1["provider"] == "github"))
    (github_identity && github_identity["provider_id"]) || meta["provider_id"]
  end

  defp build_profile(id, user, meta) do
    %{
      github_id: parse_int(id),
      github_username: meta["user_name"] || meta["preferred_username"] || "unknown",
      name: meta["full_name"] || meta["name"] || meta["user_name"] || "GitHub User",
      email: user["email"],
      avatar_url: meta["avatar_url"]
    }
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_binary(val), do: String.to_integer(val)

  defp generate_code_verifier do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_code_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end
end
