defmodule AlgedoniaWeb.DaemonSocket do
  @moduledoc """
  Socket for daemon WebSocket connections with signed token authentication.
  """
  use Phoenix.Socket
  alias Algedonia.Accounts

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
      {:ok, %{user_id: user_id}} when not is_nil(user_id) ->
        case Accounts.get_user(user_id) do
          nil ->
            :error

          _user ->
            socket =
              socket
              |> assign(:daemon_id, daemon_id)
              |> assign(:daemon_name, daemon_name)
              |> assign(:user_id, user_id)

            {:ok, socket}
        end

      {:ok, _claims} ->
        :error

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "daemon_socket:#{socket.assigns.daemon_id}"
end
