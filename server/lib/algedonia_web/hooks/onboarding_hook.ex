defmodule AlgedoniaWeb.OnboardingHook do
  @moduledoc """
  LiveView on_mount hook for the onboarding flow.
  Loads current_user and github_token from session; redirects if not logged in.
  Also loads existing workspace for resume logic.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias Algedonia.Accounts

  def on_mount(:default, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/")}

      user_id ->
        case Accounts.get_user(user_id) do
          nil ->
            {:halt, redirect(socket, to: "/")}

          user ->
            workspaces = Accounts.list_workspaces_for_user(user.id)

            socket =
              socket
              |> assign(:current_user, user)
              |> assign(:github_token, session["github_token"])
              |> assign(:existing_workspace, List.first(workspaces))

            {:cont, socket}
        end
    end
  end
end
