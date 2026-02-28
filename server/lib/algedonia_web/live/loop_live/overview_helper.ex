defmodule AlgedoniaWeb.LoopLive.OverviewHelper do
  @moduledoc """
  Overview generation helper for LoopLive.Show. Manages AI-generated
  overview content: initiating generation, extracting from tickets,
  persisting results, and handling completion callbacks.
  Used as a helper by LoopLive.Show — all functions take and return a socket.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Algedonia.{Daemons, Terminals, Tickets}
  alias AlgedoniaWeb.DaemonChannel

  @doc """
  Assigns default overview-related state to the socket.
  """
  @spec init_assigns(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init_assigns(socket) do
    socket
    |> assign(:overview_content, overview_from_ticket(socket.assigns[:ticket]))
    |> assign(:overview_loading, false)
    |> assign(:overview_job_id, nil)
  end

  @doc """
  Starts overview generation on a daemon if the ticket has no existing overview
  and no generation is already in progress.

  Returns the socket unchanged if generation is not needed or no daemon is available.
  """
  @spec maybe_start_overview_generation(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_start_overview_generation(socket) do
    cond do
      socket.assigns.ticket == nil ->
        socket

      socket.assigns.ticket.overview != nil ->
        assign(socket, :overview_content, socket.assigns.ticket.overview)

      socket.assigns.overview_loading ->
        socket

      true ->
        case Daemons.find_online() do
          {:error, :no_online_daemon} ->
            socket

          {:ok, daemon} ->
            job_id = "overview-#{socket.assigns.loop_id}-#{System.unique_integer([:positive])}"
            Terminals.subscribe(job_id)

            DaemonChannel.push_start_loop(daemon.name, job_id, %{
              "role" => "overview",
              "agent_type" => "claude_code",
              "model" =>
                Application.get_env(:algedonia, :overview_model, "claude-haiku-4-5-20251001"),
              "task" => overview_task(socket)
            })

            socket
            |> assign(:overview_loading, true)
            |> assign(:overview_job_id, job_id)
        end
    end
  end

  @doc """
  Extracts the overview content from a ticket, returning `nil` if unavailable.
  """
  @spec overview_from_ticket(map() | nil) :: String.t() | nil
  def overview_from_ticket(%{overview: overview}) when is_binary(overview), do: overview
  def overview_from_ticket(_), do: nil

  @doc """
  Handles the `:terminal_ended` callback for an overview generation job.

  Reads the generated overview from the terminal scrollback, persists it
  to the ticket, and updates the socket assigns.
  """
  @spec handle_overview_ended(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_overview_ended(socket, loop_id) do
    overview = Terminals.get_scrollback(loop_id)
    persist_overview(socket.assigns.ticket, overview)

    socket
    |> assign(:overview_loading, false)
    |> assign(:overview_job_id, nil)
    |> assign(:overview_content, overview)
  end

  # -- Private --

  defp persist_overview(%{id: _} = ticket, content) when is_binary(content) do
    Tickets.update_overview(ticket, content)
  end

  defp persist_overview(_, _), do: :ok

  defp overview_task(socket) do
    ticket = socket.assigns.ticket
    loop = socket.assigns.loop_record

    """
    You are generating a concise overview panel for a coding task. This will be displayed in a small sidebar, so be brief and scannable. Output only markdown, no commentary.

    ## Input Context

    **Ticket:** #{ticket.title}
    #{ticket.description || "(no description)"}

    **Acceptance Criteria:**
    #{ticket.acceptance_criteria || "(none specified)"}

    **Loop Task:** #{loop.title}
    #{loop.description || "(no description)"}

    **Rubric:**
    #{socket.assigns.rubric || "(none)"}

    ## Output Format

    Write compact markdown with exactly these sections:

    ### Context
    One short paragraph summarizing what this task is about and why it matters.

    ### Acceptance Criteria
    - Bullet list of concrete, testable criteria derived from the ticket and rubric
    - Keep each bullet to one line

    ### Scope
    Brief note on which files/areas are likely affected and any constraints.

    Rules:
    - Be concise — the panel is 24rem wide
    - No filler phrases ("This task aims to...", "The goal is...")
    - Start each section with substance, not preamble
    - Use **bold** for key terms only
    """
  end
end
