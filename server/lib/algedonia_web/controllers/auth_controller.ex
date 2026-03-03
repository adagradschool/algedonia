defmodule AlgedoniaWeb.AuthController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Accounts
  alias Algedonia.Auth.{GithubDevice, Supabase}
  alias Algedonia.Workspaces

  def github(conn, _params) do
    {url, code_verifier} = Supabase.authorize_url()

    conn
    |> put_session(:pkce_code_verifier, code_verifier)
    |> redirect(external: url)
  end

  def callback(conn, %{"code" => code}) do
    code_verifier = get_session(conn, :pkce_code_verifier)

    with {:ok, profile, provider_token} <-
           Supabase.exchange_code_for_user(code, code_verifier),
         {:ok, user} <- Accounts.get_or_create_user_from_github(profile) do
      Workspaces.accept_pending_invitations(user)
      workspaces = Accounts.list_workspaces_for_user(user.id)

      conn =
        conn
        |> delete_session(:pkce_code_verifier)
        |> put_session(:user_id, user.id)
        |> put_session(:display_name, user.github_username)
        |> maybe_put_github_token(provider_token)

      case workspaces do
        [workspace | _] ->
          conn
          |> put_session(:current_workspace_id, workspace.id)
          |> put_session(:current_workspace_slug, workspace.slug)
          |> redirect(to: ~p"/w/#{workspace.slug}/tickets")

        [] ->
          redirect(conn, to: ~p"/onboarding")
      end
    else
      {:error, reason} ->
        conn
        |> put_flash(:error, "Authentication failed: #{reason}")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Missing authorization code.")
    |> redirect(to: ~p"/")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end

  defp maybe_put_github_token(conn, nil), do: conn
  defp maybe_put_github_token(conn, token), do: put_session(conn, :github_token, token)

  def device_code(conn, _params) do
    case GithubDevice.request_device_code() do
      {:ok, result} ->
        json(conn, %{
          user_code: result.user_code,
          verification_uri: result.verification_uri,
          device_code: result.device_code,
          expires_in: result.expires_in,
          interval: result.interval
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: reason})
    end
  end

  def device_poll(conn, %{"device_code" => device_code}) do
    with {:ok, access_token} <- GithubDevice.poll_for_token(device_code),
         {:ok, profile} <- GithubDevice.get_user_info(access_token),
         {:ok, user} <- Accounts.get_or_create_user_from_github(profile) do
      Workspaces.accept_pending_invitations(user)

      token =
        Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{
          user_id: user.id,
          github_id: user.github_id
        })

      json(conn, %{status: "ok", token: token, user: %{id: user.id, name: user.name}})
    else
      {:pending, reason} ->
        conn
        |> put_status(202)
        |> json(%{status: "pending", reason: reason})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", error: reason})
    end
  end

  def device_poll(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing device_code parameter"})
  end
end
