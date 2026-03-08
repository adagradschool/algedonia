defmodule Algedonia.Tickets.Planning do
  @moduledoc """
  Planning workflow operations — start work and start planning transitions.
  """
  alias Algedonia.{Daemons, Loops, Skills, Tickets, Workspaces}
  alias Algedonia.Skills.Error
  alias Algedonia.Tickets.Ticket

  @type start_work_error :: atom() | {:invalid_checker_config, [Error.t()]}

  @doc """
  Starts work on a ticket by resolving or creating a work loop.

  Only tickets in `:planning` or `:halted` status can start work.
  Returns `{:ok, loop_id}` on success or `{:error, reason}` on failure.
  """
  @spec start_work(Ticket.t(), keyword()) ::
          {:ok, Algedonia.Types.id()} | {:error, start_work_error()}
  def start_work(ticket, opts \\ [])

  def start_work(%Ticket{status: status}, _opts) when status not in [:planning, :halted] do
    {:error, :invalid_status}
  end

  def start_work(%Ticket{} = ticket, opts) do
    checker_config = Keyword.get(opts, :checker_config)

    with {:ok, checker_config} <- normalize_checker_config(checker_config, opts),
         :ok <- ensure_valid_daemon(ticket),
         {:ok, loop_id} <- ensure_work_loop(ticket, checker_config: checker_config) do
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

  @doc """
  Resolves the existing task loop for a ticket, or creates one if absent.
  """
  @spec ensure_work_loop(Ticket.t(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def ensure_work_loop(%Ticket{} = ticket, opts \\ []), do: resolve_work_loop(ticket, opts)

  @doc """
  Resolves the persisted planning loop for a ticket and ensures single-step history exists.

  Only tickets in `:planning` or `:halted` status are eligible.
  """
  @spec start_planning_work(Ticket.t()) :: {:ok, binary()} | {:error, atom()}
  def start_planning_work(%Ticket{status: status}) when status not in [:planning, :halted] do
    {:error, :invalid_status}
  end

  def start_planning_work(%Ticket{} = ticket) do
    with {:ok, loop} <- resolve_planning_loop(ticket),
         {:ok, _step} <- ensure_planning_step(loop) do
      {:ok, loop.id}
    else
      {:error, _} = error -> error
      _ -> {:error, :loop_create_failed}
    end
  end

  defp resolve_work_loop(%Ticket{} = ticket, opts) do
    checker_config = Keyword.get(opts, :checker_config)

    case Loops.list_task_loops_for_ticket(ticket.id) do
      [] ->
        create_single_loop(ticket, checker_config)

      [loop | _] ->
        maybe_update_checker_config(loop, checker_config)
    end
  end

  defp create_single_loop(ticket, checker_config) do
    attrs = %{
      workspace_id: ticket.workspace_id,
      ticket_id: ticket.id,
      title: ticket.title,
      description: ticket.description || "",
      role: :task,
      max_attempts: ticket.max_attempts,
      rubric: ticket.rubric || "",
      checker_config: checker_config
    }

    case Loops.create_loop(attrs) do
      {:ok, loop} -> {:ok, loop.id}
      {:error, _changeset} -> {:error, :loop_create_failed}
    end
  end

  defp maybe_update_checker_config(loop, nil), do: {:ok, loop.id}

  defp maybe_update_checker_config(loop, checker_config) do
    case Loops.update_loop(loop, %{checker_config: checker_config}) do
      {:ok, updated} -> {:ok, updated.id}
      {:error, _changeset} -> {:error, :loop_update_failed}
    end
  end

  defp resolve_planning_loop(%Ticket{} = ticket) do
    case Loops.list_planning_loops_for_ticket(ticket.id) do
      [loop | _] ->
        {:ok, loop}

      [] ->
        attrs = %{
          workspace_id: ticket.workspace_id,
          ticket_id: ticket.id,
          title: "Planning: #{ticket.title}",
          description: ticket.description || "",
          role: :planning,
          max_attempts: 1,
          rubric: ticket.rubric || ""
        }

        case Loops.create_loop(attrs) do
          {:ok, loop} -> {:ok, loop}
          {:error, _changeset} -> {:error, :loop_create_failed}
        end
    end
  end

  defp ensure_planning_step(loop) do
    case Loops.list_steps_for_loop(loop.id) do
      [] ->
        Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      [step | _] ->
        {:ok, step}
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

  defp ensure_repo_ready(%Ticket{workspace_id: workspace_id}, daemon_name) do
    workspace = Workspaces.get_workspace!(workspace_id)

    if workspace.github_repo_url && !Daemons.repo_ready?(daemon_name, workspace.slug) do
      {:error, :daemon_repo_not_ready}
    else
      :ok
    end
  end

  defp normalize_checker_config(nil, _opts), do: {:ok, nil}
  defp normalize_checker_config([], _opts), do: {:ok, nil}

  defp normalize_checker_config(checker_config, opts) do
    skills_opts = Keyword.take(opts, [:skills_root])

    case Skills.validate_checker_config(checker_config, skills_opts) do
      {:ok, invocations, _registry} -> {:ok, build_checker_config(invocations)}
      {:error, errors, _registry} -> {:error, {:invalid_checker_config, errors}}
    end
  end

  defp build_checker_config([]), do: nil

  defp build_checker_config(invocations) do
    %{
      "steps" =>
        Enum.map(invocations, fn invocation ->
          %{"skill" => invocation.skill}
          |> maybe_put_params(invocation.params)
        end)
    }
  end

  defp maybe_put_params(entry, nil), do: entry
  defp maybe_put_params(entry, params), do: Map.put(entry, "params", params)
end
