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
    manual_step_selected? = socket.assigns[:manual_step_selected?] == true

    selected_step_id =
      selected_step_id(
        step_history,
        socket.assigns[:selected_step_id],
        current_step_id,
        manual_step_selected?
      )

    manual_step_selected? =
      manual_step_selected? and is_binary(selected_step_id) and
        selected_step_id == socket.assigns[:selected_step_id]

    socket
    |> assign(:history, history)
    |> assign(:step_history, step_history)
    |> assign(:selected_step_id, selected_step_id)
    |> assign(:current_step_id, current_step_id)
    |> assign(:manual_step_selected?, manual_step_selected?)
    |> assign(:final_verdict, extract_final_verdict(history))
  end

  @doc """
  Clears explicit selection before history assignment while auto-follow is enabled.
  """
  @spec prepare_history_update(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def prepare_history_update(socket) do
    if socket.assigns[:manual_step_selected?] == true do
      socket
    else
      assign(socket, :selected_step_id, nil)
    end
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

  defp selected_step_id([], _selected, _current_step_id, _manual_selected?), do: nil

  defp selected_step_id(history, selected, current_step_id, manual_selected?) do
    cond do
      manual_selected? && is_binary(selected) && Enum.any?(history, &(&1.id == selected)) ->
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

      latest_id = TaskLoopOrchestrator.latest_step_terminal_id(loop_id) ->
        if Enum.any?(history, &(&1.id == latest_id)), do: latest_id

      true ->
        history |> List.last() |> Map.get(:id)
    end
  end

  defp current_step_id_from_history_status(history) do
    history
    |> Enum.filter(fn entry -> entry.status == "running" end)
    |> List.last()
  end
end
