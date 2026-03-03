defmodule AlgedoniaWeb.LoopLive.OverviewHelper do
  @moduledoc """
  Overview helper for LoopLive.Show.

  Overview now renders ticket details directly; no daemon generation is used.
  """

  import Phoenix.Component, only: [assign: 3]

  @doc """
  Assigns default overview-related state to the socket.
  """
  @spec init_assigns(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init_assigns(socket) do
    socket
    |> assign(:overview_content, nil)
    |> assign(:overview_loading, false)
    |> assign(:overview_job_id, nil)
  end

  @doc """
  No-op kept for compatibility with existing callsites.
  """
  @spec maybe_start_overview_generation(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_start_overview_generation(socket), do: socket

  @doc """
  No-op kept for compatibility with existing message handling.
  """
  @spec handle_overview_ended(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_overview_ended(socket, _loop_id), do: socket
end
