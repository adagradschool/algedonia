defmodule Algedonia.TaskLoopHistory do
  @moduledoc """
  In-memory step history tracking for task loop maker/checker cycles.
  Manages history entries, completion, and PubSub broadcasting.
  """

  @doc "Creates a new history entry."
  @spec new_entry(String.t(), non_neg_integer(), String.t()) :: map()
  def new_entry(role, attempt, status) do
    %{
      id: Ecto.UUID.generate(),
      role: role,
      attempt: attempt,
      status: status,
      started_at: DateTime.utc_now()
    }
  end

  @doc "Returns the ID of the currently running entry, or nil."
  @spec current_running_id(map(), binary()) :: binary() | nil
  def current_running_id(state, loop_id) do
    state.task_history
    |> Map.get(loop_id, [])
    |> Enum.reverse()
    |> Enum.find(&(&1.status == "running"))
    |> entry_id()
  end

  @doc "Returns the ID of the latest entry, or nil."
  @spec latest_id(map(), binary()) :: binary() | nil
  def latest_id(state, loop_id) do
    state.task_history |> Map.get(loop_id, []) |> List.last() |> entry_id()
  end

  @doc "Appends a new history entry and broadcasts the update."
  @spec append(map(), binary(), map()) :: map()
  def append(state, loop_id, entry) do
    h = Map.update(state.task_history, loop_id, [entry], fn h -> h ++ [entry] end)
    broadcast(loop_id, h[loop_id])
    %{state | task_history: h}
  end

  @doc "Marks the last matching running entry as completed with the given attrs."
  @spec complete_last(map(), binary(), String.t(), non_neg_integer(), keyword()) :: map()
  def complete_last(state, loop_id, role, attempt, attrs) do
    updated =
      state.task_history
      |> Map.get(loop_id, [])
      |> Enum.reverse()
      |> Enum.map(fn e ->
        if e.role == role && e.attempt == attempt && e.status == "running" do
          Map.merge(e, attrs |> Map.new() |> Map.put(:finished_at, DateTime.utc_now()))
        else
          e
        end
      end)
      |> Enum.reverse()

    broadcast(loop_id, updated)
    %{state | task_history: Map.put(state.task_history, loop_id, updated)}
  end

  defp entry_id(nil), do: nil
  defp entry_id(e), do: Map.get(e, :id)

  defp broadcast(loop_id, history) do
    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      "loop:#{loop_id}",
      {:loop_history_updated, history}
    )
  end
end
