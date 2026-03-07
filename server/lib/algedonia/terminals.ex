defmodule Algedonia.Terminals do
  @moduledoc """
  Context module for terminal streaming. Manages per-loop terminal buffers.
  """
  import Ecto.Query, only: [from: 2]

  alias Algedonia.Loops.{Loop, LoopStep}
  alias Algedonia.PubSub.Topics
  alias Algedonia.Repo
  alias Algedonia.TenantScope
  alias Algedonia.Terminals.{TerminalBuffer, TerminalSupervisor}

  @doc "Starts a terminal buffer for the given loop_id."
  def start_buffer(loop_id) do
    workspace_id = resolve_workspace_id(loop_id)

    case TerminalSupervisor.start_child({loop_id, workspace_id}) do
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
  def subscribe(workspace_id, loop_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, Topics.terminal(workspace_id, loop_id))
  end

  @doc "Unsubscribes the caller from terminal events for loop_id."
  def unsubscribe(workspace_id, loop_id) do
    Phoenix.PubSub.unsubscribe(Algedonia.PubSub, Topics.terminal(workspace_id, loop_id))
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

  defp resolve_workspace_id(terminal_id) do
    case TenantScope.get_workspace() do
      nil ->
        nil

      workspace_id ->
        TenantScope.with_workspace(workspace_id, fn ->
          resolve_workspace_id_in_scope(terminal_id)
        end)
    end
  end

  defp resolve_workspace_id_in_scope(terminal_id) do
    case Repo.get(Loop, terminal_id) do
      %Loop{workspace_id: workspace_id} ->
        workspace_id

      nil ->
        from(s in LoopStep,
          join: l in Loop,
          on: l.id == s.loop_id,
          where: s.id == ^terminal_id,
          select: l.workspace_id
        )
        |> Repo.one()
    end
  end
end
