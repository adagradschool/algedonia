defmodule Algedonia.Tickets.Planning do
  @moduledoc """
  Planning workflow operations — start work and start planning transitions.
  """
  alias Algedonia.Tickets
  alias Algedonia.Tickets.Ticket

  @doc """
  Starts work on a ticket by resolving or creating a work loop.

  Only tickets in `:planning` or `:halted` status can start work.
  Returns `{:ok, loop_id}` on success or `{:error, reason}` on failure.
  """
  @spec start_work(Ticket.t()) :: {:ok, binary()} | {:error, atom()}
  def start_work(%Ticket{status: status}) when status not in [:planning, :halted] do
    {:error, :invalid_status}
  end

  def start_work(%Ticket{} = ticket) do
    case resolve_work_loop(ticket) do
      {:ok, loop_id} ->
        mark_in_progress(ticket)
        {:ok, loop_id}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Moves a backlog ticket to planning status.

  Returns `{:ok, ticket}` or `{:error, reason}`.
  """
  @spec start_planning(Ticket.t()) :: {:ok, Ticket.t()} | {:error, atom() | Ecto.Changeset.t()}
  def start_planning(%Ticket{status: :backlog} = ticket) do
    Tickets.update_ticket(ticket, %{status: :planning})
  end

  def start_planning(%Ticket{}), do: {:error, :invalid_status}

  defp resolve_work_loop(%Ticket{} = ticket) do
    case Algedonia.Dags.get_dag_by_ticket(ticket.id) do
      nil ->
        create_single_loop(ticket)

      dag ->
        case dag.loops do
          [loop | _] -> {:ok, loop.id}
          [] -> create_loop_for_dag(dag, ticket)
        end
    end
  end

  defp create_single_loop(ticket) do
    dag_data = %{
      "loops" => [
        %{
          "temp_id" => "primary",
          "title" => ticket.title,
          "description" => ticket.description || "",
          "role" => "task",
          "max_attempts" => ticket.max_attempts,
          "rubric" => ticket.rubric || ""
        }
      ],
      "dependencies" => []
    }

    case Algedonia.Dags.create_dag_with_loops(%{ticket_id: ticket.id}, dag_data) do
      {:ok, dag} -> {:ok, dag.loops |> List.first() |> Map.fetch!(:id)}
      {:error, _step, _changeset, _changes} -> {:error, :dag_create_failed}
    end
  end

  defp create_loop_for_dag(dag, ticket) do
    attrs = %{
      dag_id: dag.id,
      title: ticket.title,
      description: ticket.description || "",
      role: :task,
      max_attempts: ticket.max_attempts,
      rubric: ticket.rubric || ""
    }

    case Algedonia.Loops.create_loop(attrs) do
      {:ok, loop} -> {:ok, loop.id}
      {:error, _changeset} -> {:error, :loop_create_failed}
    end
  end

  defp mark_in_progress(%Ticket{status: :in_progress}), do: :ok

  defp mark_in_progress(%Ticket{} = ticket) do
    _ = Tickets.update_ticket(ticket, %{status: :in_progress})
    :ok
  end
end
