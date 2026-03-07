defmodule Algedonia.Terminals.TerminalBuffer do
  @moduledoc """
  GenServer per loop_id that holds raw binary scrollback and broadcasts new data via PubSub.
  """
  use GenServer, restart: :temporary
  alias Algedonia.PubSub.Topics
  alias Algedonia.TenantScope

  @max_bytes 8 * 1024 * 1024
  @cleanup_delay :timer.minutes(5)

  # --- Client API ---

  def start_link({loop_id, workspace_id}) do
    GenServer.start_link(__MODULE__, {loop_id, workspace_id},
      name: {:via, Registry, {Algedonia.Terminals.Registry, loop_id}}
    )
  end

  def start_link(loop_id), do: start_link({loop_id, TenantScope.get_workspace()})

  def append(pid, data) do
    GenServer.cast(pid, {:append, data})
  end

  def get_scrollback(pid) do
    GenServer.call(pid, :get_scrollback)
  end

  # --- Server Callbacks ---

  @impl true
  def init({loop_id, workspace_id}) do
    if workspace_id, do: TenantScope.put_workspace(workspace_id)

    {:ok,
     %{
       loop_id: loop_id,
       workspace_id: workspace_id,
       chunks: :queue.new(),
       byte_size: 0,
       ended: false
     }}
  end

  @impl true
  def handle_cast({:append, data}, state) do
    chunk_bytes = byte_size(data)
    chunks = :queue.in(data, state.chunks)
    total_bytes = state.byte_size + chunk_bytes
    {trimmed_chunks, trimmed_size} = trim_chunks(chunks, total_bytes)

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.terminal(state.workspace_id, state.loop_id),
      {:terminal_data, state.loop_id, data}
    )

    {:noreply, %{state | chunks: trimmed_chunks, byte_size: trimmed_size}}
  end

  @impl true
  def handle_call(:get_scrollback, _from, state) do
    scrollback =
      state.chunks
      |> :queue.to_list()
      |> IO.iodata_to_binary()

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

  defp trim_chunks(chunks, total_bytes) when total_bytes <= @max_bytes do
    {chunks, total_bytes}
  end

  defp trim_chunks(chunks, total_bytes) do
    case :queue.out(chunks) do
      {{:value, head}, rest} ->
        trim_chunks(rest, total_bytes - byte_size(head))

      {:empty, _} ->
        {:queue.new(), 0}
    end
  end
end
