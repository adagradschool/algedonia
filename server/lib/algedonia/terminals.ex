defmodule Algedonia.Terminals do
  @moduledoc """
  Context module for terminal streaming. Manages per-loop terminal buffers.
  """

  alias Algedonia.Terminals.{TerminalBuffer, TerminalSupervisor}

  @doc "Starts a terminal buffer for the given loop_id."
  def start_buffer(loop_id) do
    case TerminalSupervisor.start_child(loop_id) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc "Stops the terminal buffer for the given loop_id."
  def stop_buffer(loop_id) do
    case lookup(loop_id) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      :error -> :ok
    end
  end

  @doc "Appends terminal data to the buffer for loop_id. Starts buffer if needed."
  def append(loop_id, data) do
    case ensure_buffer(loop_id) do
      {:ok, pid} -> TerminalBuffer.append(pid, data)
      error -> error
    end
  end

  @doc "Returns the full scrollback for loop_id."
  def get_scrollback(loop_id) do
    case lookup(loop_id) do
      {:ok, pid} -> TerminalBuffer.get_scrollback(pid)
      :error -> ""
    end
  end

  @doc "Subscribes the caller to terminal events for loop_id."
  def subscribe(loop_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, "terminal:#{loop_id}")
  end

  @doc "Returns true if a buffer is active for loop_id."
  def active?(loop_id) do
    case lookup(loop_id) do
      {:ok, _pid} -> true
      :error -> false
    end
  end

  @doc "Notifies the buffer that the terminal has ended."
  def terminal_ended(loop_id) do
    case lookup(loop_id) do
      {:ok, pid} -> send(pid, :terminal_ended)
      :error -> :ok
    end
  end

  defp lookup(loop_id) do
    case Registry.lookup(Algedonia.Terminals.Registry, loop_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp ensure_buffer(loop_id) do
    case lookup(loop_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> start_buffer(loop_id)
    end
  end
end
