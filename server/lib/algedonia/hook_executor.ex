defmodule Algedonia.HookExecutor do
  @moduledoc """
  Fires transition hooks when a ticket changes status.

  For each matching hook, creates a `:hook` role loop linked to the ticket
  and dispatches it for agent execution. On hook failure, the ticket is
  moved to `:halted` with `skip_hooks: true` to prevent recursive chains.
  """

  alias Algedonia.{Agents, Daemons, Loops, PromptBuilder, Tickets, Workspaces}
  alias Algedonia.PubSub.Topics
  alias Algedonia.TenantScope
  alias Algedonia.Tickets.Ticket
  alias AlgedoniaWeb.DaemonChannel

  @doc """
  Fires all enabled hooks matching a status transition.

  Creates a hook loop for each matching hook and dispatches to the daemon.
  """
  @spec fire_hooks(integer(), Ticket.t(), atom(), atom()) :: :ok
  def fire_hooks(workspace_id, %Ticket{} = ticket, from_status, to_status) do
    hooks = Workspaces.get_hooks_for_transition(workspace_id, from_status, to_status)

    Enum.each(hooks, fn hook ->
      execute_hook(hook, ticket, from_status, to_status)
    end)
  end

  defp execute_hook(hook, ticket, from_status, to_status) do
    with {:ok, loop} <- create_hook_loop(hook, ticket) do
      broadcast_hook_loop(ticket.workspace_id, ticket.id, loop)
      maybe_dispatch_hook_loop(loop, hook, ticket, from_status, to_status)
    end
  end

  defp create_hook_loop(hook, ticket) do
    Loops.create_loop(%{
      workspace_id: ticket.workspace_id,
      ticket_id: ticket.id,
      title: "Hook: #{hook.from_status} → #{hook.to_status}",
      description: hook.instruction,
      role: :hook,
      status: :pending,
      max_attempts: Workspaces.iteration_budget(ticket.workspace_id)
    })
  end

  defp broadcast_hook_loop(workspace_id, ticket_id, loop) do
    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.ticket_loops(workspace_id, ticket_id),
      {:hook_loop_created, loop}
    )
  end

  @doc """
  Builds the agent context envelope for a hook execution.
  """
  @spec build_context(Algedonia.Workspaces.TransitionHook.t(), Ticket.t(), atom(), atom()) ::
          map()
  def build_context(hook, ticket, from_status, to_status) do
    workspace = Workspaces.get_workspace!(ticket.workspace_id)

    %{
      instruction: hook.instruction,
      ticket: %{
        id: ticket.id,
        title: ticket.title,
        description: ticket.description,
        acceptance_criteria: ticket.acceptance_criteria,
        status: to_status,
        previous_status: from_status
      },
      github_repo_url: workspace.github_repo_url
    }
  end

  @doc """
  Handles hook failure by marking the loop as failed and the ticket as halted.
  """
  @spec handle_failure(Algedonia.Loops.Loop.t(), Ticket.t()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def handle_failure(loop, ticket) do
    {:ok, _} = Loops.update_loop_status(loop, :failed)
    Tickets.update_ticket(ticket, %{status: :halted}, skip_hooks: true)
  end

  @doc """
  Handles attempt completion events for hook loops.
  """
  @spec handle_attempt_complete(binary(), map(), keyword()) :: :ok
  def handle_attempt_complete(loop_id, payload, opts \\ []) do
    case Keyword.get(opts, :workspace_id) do
      nil ->
        :ok

      workspace_id ->
        TenantScope.with_workspace(workspace_id, fn ->
          loop_id
          |> Loops.get_loop()
          |> maybe_complete_hook(payload)
        end)
    end

    :ok
  end

  @doc """
  Handles attempt error events for hook loops.
  """
  @spec handle_attempt_error(binary(), map(), keyword()) :: :ok
  def handle_attempt_error(loop_id, _payload, opts \\ []) do
    case Keyword.get(opts, :workspace_id) do
      nil ->
        :ok

      workspace_id ->
        TenantScope.with_workspace(workspace_id, fn ->
          loop_id
          |> Loops.get_loop()
          |> maybe_fail_hook()
        end)
    end

    :ok
  end

  defp dispatch_hook_loop(loop, daemon_name, hook, ticket, from_status, to_status) do
    context = build_context(hook, ticket, from_status, to_status)
    task = PromptBuilder.hook_task(context)
    workspace = Workspaces.get_workspace!(ticket.workspace_id)

    opts =
      %{
        "role" => "hook",
        "agent_type" => Agents.ticket_agent_type(ticket),
        "ticket_id" => ticket.id,
        "workspace_slug" => workspace.slug,
        "task" => task
      }

    DaemonChannel.push_start_loop(daemon_name, loop.id, opts)

    :ok
  end

  defp maybe_dispatch_hook_loop(loop, hook, ticket, from_status, to_status) do
    with {:ok, daemon} <- Daemons.find_online(),
         :ok <- check_repo_ready(daemon.name, ticket),
         {:ok, loop} <- mark_hook_running(loop, daemon.id) do
      dispatch_hook_loop(loop, daemon.name, hook, ticket, from_status, to_status)
    else
      _ -> :ok
    end
  end

  defp mark_hook_running(loop, daemon_id) do
    attempt = max(loop.current_attempt, 0) + 1

    with {:ok, loop} <-
           Loops.update_loop(loop, %{
             status: :running,
             assigned_daemon_id: daemon_id,
             current_attempt: attempt
           }),
         {:ok, _step} <-
           Loops.create_step(%{
             loop_id: loop.id,
             role: "hook",
             attempt: attempt,
             status: "running",
             started_at: DateTime.utc_now()
           }) do
      {:ok, loop}
    end
  end

  defp check_repo_ready(daemon_name, %Ticket{workspace_id: workspace_id}) do
    workspace = Workspaces.get_workspace!(workspace_id)

    if workspace.github_repo_url && !Daemons.repo_ready?(daemon_name, workspace.slug) do
      {:error, :repo_not_ready}
    else
      :ok
    end
  end

  defp maybe_complete_hook(%{role: :hook} = loop, payload) do
    if Map.get(payload, "exit_code", 0) == 0 do
      _ = Loops.update_loop_status(loop, :passed)
    else
      ticket = Tickets.get_ticket!(loop.ticket_id)
      _ = handle_failure(loop, ticket)
    end

    :ok
  end

  defp maybe_complete_hook(_loop, _payload), do: :ok

  defp maybe_fail_hook(%{role: :hook} = loop) do
    ticket = Tickets.get_ticket!(loop.ticket_id)
    _ = handle_failure(loop, ticket)
    :ok
  end

  defp maybe_fail_hook(_loop), do: :ok
end
