defmodule AlgedoniaWeb.LoopLive.ContextHelper do
  @moduledoc """
  Startup and routing helper for LoopLive.Show. Handles loop context
  resolution, page title building, subscriptions, and ad-hoc task
  construction for planning sessions.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Algedonia.{Loops, Tickets}

  @status_to_stage %{
    running_checker: "checker",
    passed: "completed",
    failed: "failed"
  }

  @planning_workflow_instructions """
  Project identity and naming:
  - `.algedonia/` is Algedonia orchestration tooling config.
  - Do not assume the workspace repository/product is named "Algedonia".
  - Use the repository's actual identity (README, package/module metadata, existing docs) when writing project context.
  - If ticket wording uses "Algedonia" ambiguously, treat it as the orchestration tool unless an explicit rename is requested.

  Planning workflow:
  1. Read the repository context before asking questions.
  2. Ask the user one clarifying question at a time and wait for a response.
  3. Once the user approves, post the final implementation plan as a ticket comment.
  4. Always update the ticket title, description, acceptance criteria, and rubric to match the approved plan.
  5. Before writing the updated rubric, consult notes/rubrics.md and align the rubric with repository standards.

  Required AG CLI commands (run these, do not just describe them):
  - Add plan comment:
    ag ticket comment ~TICKET_REF --author "planner" --body "<final plan markdown>"
  - Update ticket fields:
    ag ticket update ~TICKET_REF --title "<title>" --description "<description>" --acceptance-criteria "<acceptance criteria>" --rubric "<rubric>"
  - Fetch existing comments when needed:
    ag ticket comments ~TICKET_REF --json

  Do not implement code in this planning session.
  """

  @doc """
  Returns the stage string for a given loop status atom.
  Defaults to `"maker"` for unrecognized statuses.
  """
  @spec stage_for_status(atom()) :: String.t()
  def stage_for_status(status), do: Map.get(@status_to_stage, status, "maker")

  @doc """
  Resolves a loop reference (short ID or UUID) to a canonical loop ID.
  """
  @spec resolve_loop_id(String.t()) :: String.t()
  def resolve_loop_id(loop_ref) do
    case Loops.get_loop_by_ref(loop_ref) do
      nil -> loop_ref
      loop -> loop.id
    end
  end

  @doc """
  Assigns loop context (ticket, stage, attempt, rubric, etc.) to the socket
  from a loop ID, loading the loop and its associated ticket.
  """
  @spec assign_loop_context(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_loop_context(socket, loop_id) do
    loop = Loops.get_loop_by_ref(loop_id)

    case loop do
      nil ->
        ticket = ticket_for_route(socket)

        socket
        |> assign(:loop_record, nil)
        |> assign(:ticket, ticket)
        |> assign(:loop_title, ad_hoc_loop_title(ticket))
        |> assign(:stage, "maker")
        |> assign(:attempt, 1)
        |> assign(:rubric, "")
        |> assign(
          :acceptance_criteria,
          if(ticket, do: ticket.acceptance_criteria || "", else: "")
        )
        |> assign(:page_title, "Loop #{short_id(loop_id)}")

      loop ->
        loop = Loops.preload_ticket(loop)
        ticket = loop.dag.ticket
        stage = stage_for_status(loop.status)
        attempt = max(loop.current_attempt, 1)

        socket
        |> assign(:loop_record, loop)
        |> assign(:ticket, ticket)
        |> assign(:loop_title, loop.title)
        |> assign(:stage, stage)
        |> assign(:attempt, attempt)
        |> assign(:rubric, loop.rubric || ticket.rubric || "")
        |> assign(:acceptance_criteria, ticket.acceptance_criteria || "")
        |> assign(:page_title, "Loop #{short_id(loop_id)}")
    end
  end

  @doc """
  Subscribes to loop update PubSub events if the loop exists.
  """
  @spec maybe_subscribe_loop_updates(String.t()) :: :ok
  def maybe_subscribe_loop_updates(loop_id) do
    case Loops.get_loop_by_ref(loop_id) do
      nil -> :ok
      loop -> Loops.subscribe(loop.id)
    end
  end

  @doc """
  Subscribes to ticket and comment PubSub events if a ticket is assigned.
  """
  @spec maybe_subscribe_ticket_updates(Phoenix.LiveView.Socket.t()) :: :ok
  def maybe_subscribe_ticket_updates(socket) do
    case socket.assigns.ticket do
      %{id: ticket_id} ->
        Tickets.subscribe()
        Tickets.subscribe_comments(ticket_id)

      _ ->
        :ok
    end
  end

  @doc """
  Builds the ad-hoc task prompt for a planning session, or returns `nil`.
  """
  @spec ad_hoc_task(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def ad_hoc_task(%{assigns: %{role: "planning", ticket: ticket}}) when not is_nil(ticket) do
    ticket_ref =
      if is_integer(ticket.number), do: Integer.to_string(ticket.number), else: ticket.id

    instructions = String.replace(@planning_workflow_instructions, "~TICKET_REF", ticket_ref)

    [
      "Ticket: #{ticket.title}",
      optional_ad_hoc_section("Description", ticket.description),
      optional_ad_hoc_section("Acceptance criteria", ticket.acceptance_criteria),
      optional_ad_hoc_section("Current rubric", ticket.rubric),
      instructions
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  def ad_hoc_task(_socket), do: nil

  @doc """
  Returns `true` when the role is a planning session.
  """
  @spec planning_session?(String.t()) :: boolean()
  def planning_session?(role), do: role == "planning"

  @doc """
  Builds the page title from ticket, workspace prefix, stage, attempt, and planning flag.
  Returns `nil` when a title cannot be constructed.
  """
  @spec build_page_title(map() | nil, String.t() | nil, String.t(), integer(), boolean()) ::
          String.t() | nil
  def build_page_title(ticket, workspace_prefix, stage, attempt, planning?)

  def build_page_title(%{number: number}, prefix, _stage, _attempt, true)
      when is_integer(number) and is_binary(prefix) do
    "#{prefix}-#{number}"
  end

  def build_page_title(%{number: number}, prefix, stage, attempt, false)
      when is_integer(number) and is_binary(prefix) do
    "#{prefix}-#{number} · #{String.capitalize(stage)} ##{attempt}"
  end

  def build_page_title(_ticket, _prefix, _stage, _attempt, _planning?) do
    nil
  end

  @doc """
  Returns the workspace prefix from the socket, or `nil`.
  """
  @spec workspace_prefix(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def workspace_prefix(socket) do
    case socket.assigns[:current_workspace] do
      %{prefix: prefix} -> prefix
      _ -> nil
    end
  end

  # -- Private --

  defp ticket_for_route(socket) do
    with %{} = workspace <- socket.assigns[:current_workspace],
         ticket_ref when is_binary(ticket_ref) <- socket.assigns[:route_ticket_ref],
         true <- ticket_ref_reference?(ticket_ref) do
      Tickets.get_ticket_by_ref!(workspace.id, ticket_ref)
    else
      _ -> nil
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp ticket_ref_reference?(ticket_ref) do
    case Integer.parse(ticket_ref) do
      {_, ""} -> true
      _ -> match?({:ok, _}, Ecto.UUID.cast(ticket_ref))
    end
  end

  defp ad_hoc_loop_title(nil), do: "Ad hoc loop"
  defp ad_hoc_loop_title(ticket), do: "Planning: #{ticket.title}"

  defp optional_ad_hoc_section(_label, nil), do: nil
  defp optional_ad_hoc_section(_label, ""), do: nil
  defp optional_ad_hoc_section(label, body), do: "#{label}:\n#{body}"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: nil
end
