defmodule AlgedoniaWeb.OnboardingHook do
  @moduledoc """
  LiveView on_mount hook for the onboarding flow.
  Loads current_user from session; redirects if not logged in.
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
            {:cont, assign(socket, :current_user, user)}
        end
    end
  end
end
