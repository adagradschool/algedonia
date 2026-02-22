defmodule Algedonia.Terminals.TerminalSupervisor do
  @moduledoc """
  DynamicSupervisor for terminal buffer processes.
  """
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(loop_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Algedonia.Terminals.TerminalBuffer, loop_id}
    )
  end
end
