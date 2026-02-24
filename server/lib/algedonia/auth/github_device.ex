defmodule Algedonia.Auth.GithubDevice do
  @moduledoc """
  Handles GitHub Device Flow for daemon CLI authentication.
  """

  @device_code_url "https://github.com/login/device/code"
  @access_token_url "https://github.com/login/oauth/access_token"
  @user_api_url "https://api.github.com/user"

  def request_device_code do
    config = Application.fetch_env!(:algedonia, :github)
    client_id = Keyword.fetch!(config, :client_id)

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    body = Jason.encode!(%{"client_id" => client_id, "scope" => "read:user user:email"})

    case Req.post(@device_code_url, headers: headers, body: body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           device_code: body["device_code"],
           user_code: body["user_code"],
           verification_uri: body["verification_uri"],
           expires_in: body["expires_in"],
           interval: body["interval"] || 5
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, "GitHub device code request failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "GitHub request failed: #{inspect(reason)}"}
    end
  end

  def poll_for_token(device_code) do
    config = Application.fetch_env!(:algedonia, :github)
    client_id = Keyword.fetch!(config, :client_id)

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    body =
      Jason.encode!(%{
        "client_id" => client_id,
        "device_code" => device_code,
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
      })

    case Req.post(@access_token_url, headers: headers, body: body) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: 200, body: %{"error" => "authorization_pending"}}} ->
        {:pending, "authorization_pending"}

      {:ok, %{status: 200, body: %{"error" => "slow_down"}}} ->
        {:pending, "slow_down"}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status, body: body}} ->
        {:error, "GitHub token poll failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "GitHub request failed: #{inspect(reason)}"}
    end
  end

  def get_user_info(access_token) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"accept", "application/json"}
    ]

    case Req.get(@user_api_url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           github_id: body["id"],
           github_username: body["login"],
           name: body["name"] || body["login"],
           email: body["email"],
           avatar_url: body["avatar_url"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, "GitHub user info failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "GitHub request failed: #{inspect(reason)}"}
    end
  end
end
