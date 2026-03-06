defmodule Algedonia.Tickets.Planning do
  @moduledoc """
  Planning workflow operations — start work and start planning transitions.
  """
  alias Algedonia.{Daemons, Loops, Tickets, Workspaces}
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
    with :ok <- ensure_valid_daemon(ticket),
         {:ok, loop_id} <- resolve_work_loop(ticket) do
      mark_in_progress(ticket)
      {:ok, loop_id}
    else
      {:error, _} = error -> error
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
    case Loops.list_task_loops_for_ticket(ticket.id) do
      [] ->
        create_single_loop(ticket)

      [loop | _] ->
        {:ok, loop.id}
    end
  end

  defp create_single_loop(ticket) do
    attrs = %{
      ticket_id: ticket.id,
      title: ticket.title,
      description: ticket.description || "",
      role: :task,
      max_attempts: ticket.max_attempts,
      rubric: ticket.rubric || ""
    }

    case Loops.create_loop(attrs) do
      {:ok, loop} -> {:ok, loop.id}
      {:error, _changeset} -> {:error, :loop_create_failed}
    end
  end

  defp mark_in_progress(%Ticket{status: :in_progress}), do: :ok

  defp mark_in_progress(%Ticket{} = ticket) do
    _ = Tickets.update_ticket(ticket, %{status: :in_progress})
    :ok
  end

  defp ensure_valid_daemon(%Ticket{} = ticket) do
    with {:ok, daemon} <- Daemons.find_online() do
      ensure_repo_ready(ticket, daemon.name)
    end
  end

  defp ensure_repo_ready(%Ticket{workspace_id: workspace_id}, daemon_name)
       when is_integer(workspace_id) do
    workspace = Workspaces.get_workspace!(workspace_id)

    if workspace.github_repo_url && !Daemons.repo_ready?(daemon_name, workspace.slug) do
      {:error, :daemon_repo_not_ready}
    else
      :ok
    end
  end

  defp ensure_repo_ready(_ticket, _daemon_name), do: :ok
end
