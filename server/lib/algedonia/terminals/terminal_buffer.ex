defmodule Algedonia.Terminals.TerminalBuffer do
  @moduledoc """
  GenServer per loop_id that holds raw binary scrollback and broadcasts new data via PubSub.
  """
  use GenServer, restart: :temporary

  @max_lines 10_000
  @cleanup_delay :timer.minutes(5)

  # --- Client API ---

  def start_link(loop_id) do
    GenServer.start_link(__MODULE__, loop_id,
      name: {:via, Registry, {Algedonia.Terminals.Registry, loop_id}}
    )
  end

  def append(pid, data) do
    GenServer.cast(pid, {:append, data})
  end

  def get_scrollback(pid) do
    GenServer.call(pid, :get_scrollback)
  end

  # --- Server Callbacks ---

  @impl true
  def init(loop_id) do
    {:ok, %{loop_id: loop_id, lines: [], line_count: 0, ended: false}}
  end

  @impl true
  def handle_cast({:append, data}, state) do
    new_lines = String.split(data, "\n")
    updated_lines = state.lines ++ new_lines
    {trimmed, count} = cap_lines(updated_lines)

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      "terminal:#{state.loop_id}",
      {:terminal_data, state.loop_id, data}
    )

    {:noreply, %{state | lines: trimmed, line_count: count}}
  end

  @impl true
  def handle_call(:get_scrollback, _from, state) do
    scrollback = Enum.join(state.lines, "\n")
    {:reply, scrollback, state}
  end

  @impl true
  def handle_info(:terminal_ended, state) do
    Process.send_after(self(), :cleanup, @cleanup_delay)
    {:noreply, %{state | ended: true}}
  end

  def handle_info(:cleanup, state) do
    {:stop, :normal, state}
  end

  defp cap_lines(lines) do
    count = length(lines)

    if count > @max_lines do
      {Enum.drop(lines, count - @max_lines), @max_lines}
    else
      {lines, count}
    end
  end
end
