defmodule AlgedoniaWeb.LoopLive.Show do
  @moduledoc """
  LiveView for inspecting a loop's terminal output in real-time.
  """
  use AlgedoniaWeb, :live_view

  alias Algedonia.Daemons
  alias Algedonia.Terminals
  alias AlgedoniaWeb.DaemonChannel

  @impl true
  def mount(%{"loop_id" => loop_id}, _session, socket) do
    if connected?(socket) do
      Terminals.subscribe(loop_id)
      scrollback = Terminals.get_scrollback(loop_id)

      if scrollback != "" do
        send(self(), {:send_scrollback, scrollback})
      end
    end

    socket =
      socket
      |> assign(:loop_id, loop_id)
      |> assign(:active, Terminals.active?(loop_id))
      |> assign(:page_title, "Loop #{loop_id}")

    {:ok, socket}
  end

  @impl true
  def handle_event("start_loop", _params, socket) do
    daemons = Daemons.list_daemons()
    online = Enum.find(daemons, &(&1.status == :online))

    if online do
      DaemonChannel.push_start_loop(online.name, socket.assigns.loop_id)
      {:noreply, assign(socket, :active, true)}
    else
      {:noreply, put_flash(socket, :error, "No online daemon available")}
    end
  end

  def handle_event("terminal_input", %{"data" => data}, socket) do
    daemons = Daemons.list_daemons()
    online = Enum.find(daemons, &(&1.status == :online))

    if online do
      DaemonChannel.push_stdin_input(online.name, socket.assigns.loop_id, data)
    end

    {:noreply, socket}
  end

  def handle_event("stop_loop", _params, socket) do
    daemons = Daemons.list_daemons()
    online = Enum.find(daemons, &(&1.status == :online))

    if online do
      DaemonChannel.push_stop_loop(online.name, socket.assigns.loop_id)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:send_scrollback, scrollback}, socket) do
    encoded = Base.encode64(scrollback)
    {:noreply, push_event(socket, "terminal_scrollback", %{data: encoded})}
  end

  def handle_info({:terminal_data, _loop_id, data}, socket) do
    encoded = Base.encode64(data)
    {:noreply, push_event(socket, "terminal_data", %{data: encoded})}
  end

  def handle_info({:terminal_ended, _loop_id, exit_code}, socket) do
    socket =
      socket
      |> push_event("terminal_ended", %{exit_code: exit_code})
      |> assign(:active, false)

    {:noreply, socket}
  end
end
