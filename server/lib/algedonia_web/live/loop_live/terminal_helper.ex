defmodule AlgedoniaWeb.LoopLive.TerminalHelper do
  @moduledoc """
  Terminal management helper for LoopLive.Show. Handles terminal run
  identity resolution and WebSocket access token generation.
  Used as a helper by LoopLive.Show — all functions take and return a socket.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  alias Algedonia.Daemons
  alias AlgedoniaWeb.TerminalAccessToken

  @doc """
  Assigns terminal run identity to the socket based on the selected step.

  Sets `:terminal_run_key`, `:selected_terminal_id`, and `:terminal_stream_loop_id`
  from the current step history and selection state.
  """
  @spec assign_terminal_run(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_terminal_run(socket) do
    history = socket.assigns[:step_history] || []
    attempt = socket.assigns[:attempt] || 1
    stage = socket.assigns[:stage] || "maker"
    selected_step = selected_step(history, socket.assigns[:selected_step_id])
    current_step_id = socket.assigns[:current_step_id]

    {key, scrollback_terminal_id} =
      terminal_run_identity(selected_step, socket.assigns.loop_id, attempt, stage)

    stream_loop_id =
      terminal_stream_loop_id(selected_step, current_step_id, socket.assigns.loop_id)

    socket
    |> assign(:terminal_run_key, key)
    |> assign(:selected_terminal_id, scrollback_terminal_id)
    |> assign(:terminal_stream_loop_id, stream_loop_id)
  end

  @doc """
  Assigns WebSocket access credentials for the terminal connection.

  Sets `:terminal_ws_url` and `:terminal_ws_token` based on the current user
  and the selected terminal stream loop ID.
  """
  @spec assign_terminal_ws_access(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_terminal_ws_access(socket) do
    stream_loop_id = socket.assigns[:terminal_stream_loop_id]
    loop_record = socket.assigns[:loop_record]
    daemon_id = if loop_record, do: loop_record.assigned_daemon_id

    terminal_ws_url = daemon_terminal_ws_url(daemon_id)

    token =
      case {socket.assigns[:current_user], stream_loop_id} do
        {%{id: user_id}, loop_id} when is_binary(loop_id) and loop_id != "" ->
          TerminalAccessToken.sign(user_id, loop_id)

        _ ->
          nil
      end

    socket =
      socket |> assign(:terminal_ws_url, terminal_ws_url) |> assign(:terminal_ws_token, token)

    if connected?(socket) && terminal_ws_url && token && stream_loop_id do
      push_event(socket, "terminal_ws_updated", %{
        url: terminal_ws_url,
        token: token,
        loop_id: stream_loop_id
      })
    else
      socket
    end
  end

  defp daemon_terminal_ws_url(daemon_id) when is_binary(daemon_id) do
    case Daemons.get_daemon(daemon_id) do
      %{terminal_ws_url: url} when is_binary(url) and url != "" -> url
      _ -> Application.get_env(:algedonia, :terminal_ws_base_url)
    end
  end

  defp daemon_terminal_ws_url(_), do: Application.get_env(:algedonia, :terminal_ws_base_url)

  # -- Private --

  defp selected_step(history, selected_step_id) do
    Enum.find(history, &(&1.id == selected_step_id))
  end

  defp terminal_run_identity(nil, loop_id, attempt, stage) do
    {"attempt-#{attempt}-#{stage}", loop_id}
  end

  defp terminal_run_identity(entry, _loop_id, _attempt, _stage) do
    {"attempt-#{entry.attempt}-#{entry.role}-#{entry.id}", entry.id}
  end

  defp terminal_stream_loop_id(nil, _current_step_id, loop_id), do: loop_id

  defp terminal_stream_loop_id(entry, current_step_id, loop_id) do
    if entry.id == current_step_id do
      loop_id
    else
      nil
    end
  end
end
