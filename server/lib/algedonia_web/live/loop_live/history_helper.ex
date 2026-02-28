defmodule AlgedoniaWeb.LoopLive.HistoryHelper do
  @moduledoc """
  History tracking helper for LoopLive.Show. Manages step history,
  step selection, verdict extraction, and current-step tracking.
  Used as a helper by LoopLive.Show — all functions take and return a socket.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Algedonia.TaskLoopOrchestrator

  @doc """
  Assigns history-related state to the socket from a raw history list.

  Computes step history (filtered and sorted), selects the appropriate step,
  identifies the current step, and extracts the final verdict.
  """
  @spec assign_history(Phoenix.LiveView.Socket.t(), list()) :: Phoenix.LiveView.Socket.t()
  def assign_history(socket, history) do
    step_history = step_history(history)
    current_step_id = current_step_id(socket, step_history)

    selected_step_id =
      selected_step_id(step_history, socket.assigns[:selected_step_id], current_step_id)

    socket
    |> assign(:history, history)
    |> assign(:step_history, step_history)
    |> assign(:selected_step_id, selected_step_id)
    |> assign(:current_step_id, current_step_id)
    |> assign(:final_verdict, extract_final_verdict(history))
  end

  @doc """
  Returns true when the user is following the current (latest) step,
  i.e. no manual step selection or the selection matches the current step.
  """
  @spec following_current_step?(Phoenix.LiveView.Socket.t()) :: boolean()
  def following_current_step?(socket) do
    selected = socket.assigns[:selected_step_id]
    current = socket.assigns[:current_step_id]

    is_nil(selected) or selected == current
  end

  @doc """
  Returns true when the given verdict represents a final outcome for the loop.

  A verdict is final when it's a pass, the loop status is terminal,
  or the loop has exhausted its maximum attempts.
  """
  @spec final_outcome?(map() | nil, map() | nil) :: boolean()
  def final_outcome?(nil, _loop_record), do: false

  def final_outcome?(%{verdict: "pass"}, _loop_record), do: true

  def final_outcome?(_final_verdict, %{status: status})
      when status in [:passed, :failed],
      do: true

  def final_outcome?(_final_verdict, %{
        current_attempt: current_attempt,
        max_attempts: max_attempts
      })
      when is_integer(current_attempt) and is_integer(max_attempts),
      do: current_attempt >= max_attempts

  def final_outcome?(_final_verdict, _loop_record), do: false

  # -- Private --

  defp extract_final_verdict(history) do
    history
    |> Enum.reverse()
    |> Enum.find(fn entry ->
      entry.role == "checker" and entry.status == "completed" and Map.has_key?(entry, :verdict)
    end)
  end

  defp step_history(history) do
    history
    |> Enum.reject(fn entry -> entry.status == "handoff_invalid" end)
    |> Enum.sort_by(&step_history_sort_key/1)
  end

  defp step_history_sort_key(entry) do
    role_order = if entry.role == "maker", do: 0, else: 1
    timestamp_order = entry |> Map.get(:started_at) |> sortable_timestamp()

    {
      Map.get(entry, :attempt, 0),
      role_order,
      timestamp_order,
      Map.get(entry, :id, "")
    }
  end

  defp sortable_timestamp(nil), do: 0

  defp sortable_timestamp(%DateTime{} = timestamp) do
    DateTime.to_unix(timestamp, :microsecond)
  end

  defp sortable_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.to_unix(parsed, :microsecond)
      _ -> 0
    end
  end

  defp sortable_timestamp(_), do: 0

  defp selected_step_id([], _selected, _current_step_id), do: nil

  defp selected_step_id(history, selected, current_step_id) do
    cond do
      is_binary(selected) && Enum.any?(history, &(&1.id == selected)) ->
        selected

      is_binary(current_step_id) && Enum.any?(history, &(&1.id == current_step_id)) ->
        current_step_id

      true ->
        history |> List.last() |> Map.get(:id)
    end
  end

  defp current_step_id(_socket, []), do: nil

  defp current_step_id(socket, history) do
    loop_id = socket.assigns.loop_id

    cond do
      current = current_step_id_from_history_status(history) ->
        current.id

      current_id = TaskLoopOrchestrator.current_step_terminal_id(loop_id) ->
        if Enum.any?(history, &(&1.id == current_id)), do: current_id

      current_id = current_step_id_from_loop_context(socket, history) ->
        current_id

      latest_id = TaskLoopOrchestrator.latest_step_terminal_id(loop_id) ->
        if Enum.any?(history, &(&1.id == latest_id)), do: latest_id

      true ->
        history |> List.last() |> Map.get(:id)
    end
  end

  defp current_step_id_from_history_status(history) do
    Enum.find(history, fn entry -> entry.status == "running" end)
  end

  defp current_step_id_from_loop_context(socket, history) do
    stage = socket.assigns[:stage]
    attempt = socket.assigns[:attempt]

    role =
      case stage do
        "maker" -> "maker"
        "checker" -> "checker"
        _ -> nil
      end

    if is_integer(attempt) && is_binary(role) do
      history
      |> Enum.find(fn entry -> entry.attempt == attempt && entry.role == role end)
      |> case do
        nil -> nil
        entry -> entry.id
      end
    end
  end
end
