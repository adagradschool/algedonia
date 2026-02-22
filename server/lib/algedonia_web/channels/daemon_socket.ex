defmodule AlgedoniaWeb.DaemonSocket do
  @moduledoc """
  Socket for daemon WebSocket connections with token authentication.
  """
  use Phoenix.Socket

  alias Algedonia.Workspaces

  channel "daemon:*", AlgedoniaWeb.DaemonChannel

  @impl true
  def connect(
        %{"token" => token, "daemon_id" => daemon_id, "daemon_name" => daemon_name},
        socket,
        _connect_info
      ) do
    expected = Application.get_env(:algedonia, :project_token)
    workspace = Workspaces.get_workspace_by_invite_token(token)

    if (expected && Plug.Crypto.secure_compare(token, expected)) || workspace do
      socket =
        socket
        |> assign(:daemon_id, daemon_id)
        |> assign(:daemon_name, daemon_name)
        |> assign(:workspace_id, workspace && workspace.id)

      {:ok, socket}
    else
      :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "daemon_socket:#{socket.assigns.daemon_id}"
end
