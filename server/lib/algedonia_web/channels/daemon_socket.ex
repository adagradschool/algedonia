defmodule AlgedoniaWeb.DaemonSocket do
  @moduledoc """
  Socket for daemon WebSocket connections with signed token authentication.
  """
  use Phoenix.Socket

  channel "daemon:*", AlgedoniaWeb.DaemonChannel

  # Token validity: 7 days
  @max_age 7 * 24 * 3600

  @impl true
  def connect(
        %{"token" => token, "daemon_id" => daemon_id, "daemon_name" => daemon_name},
        socket,
        _connect_info
      ) do
    case Phoenix.Token.verify(AlgedoniaWeb.Endpoint, "daemon_auth", token, max_age: @max_age) do
      {:ok, %{user_id: user_id}} ->
        socket =
          socket
          |> assign(:daemon_id, daemon_id)
          |> assign(:daemon_name, daemon_name)
          |> assign(:user_id, user_id)

        {:ok, socket}

      {:error, _reason} ->
        # Fall back to project token for backwards compatibility in dev
        maybe_project_token_auth(token, daemon_id, daemon_name, socket)
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "daemon_socket:#{socket.assigns.daemon_id}"

  defp maybe_project_token_auth(token, daemon_id, daemon_name, socket) do
    expected = Application.get_env(:algedonia, :project_token)

    if expected && Plug.Crypto.secure_compare(token, expected) do
      socket =
        socket
        |> assign(:daemon_id, daemon_id)
        |> assign(:daemon_name, daemon_name)
        |> assign(:user_id, nil)

      {:ok, socket}
    else
      :error
    end
  end
end
