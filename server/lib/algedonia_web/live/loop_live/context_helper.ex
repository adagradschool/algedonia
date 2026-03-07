defmodule AlgedoniaWeb.LoopLive.ContextHelper do
  @moduledoc """
  Startup and routing helper for LoopLive.Show. Handles loop context
  resolution, page title building, subscriptions, and ad-hoc task
  construction for planning sessions.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Algedonia.{Loops, PromptBuilder, Tickets}

  @status_to_stage %{
    running: "running",
    passed: "completed",
    failed: "failed"
  }

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
        ticket = loop.ticket
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
  @spec maybe_subscribe_loop_updates(Algedonia.Types.id(), String.t()) :: :ok
  def maybe_subscribe_loop_updates(workspace_id, loop_id) do
    case Loops.get_loop_by_ref(loop_id) do
      nil -> :ok
      loop -> Loops.subscribe(workspace_id, loop.id)
    end
  end

  @doc """
  Subscribes to ticket and comment PubSub events if a ticket is assigned.
  """
  @spec maybe_subscribe_ticket_updates(Phoenix.LiveView.Socket.t(), Algedonia.Types.id()) :: :ok
  def maybe_subscribe_ticket_updates(socket, workspace_id) do
    case socket.assigns.ticket do
      %{id: ticket_id} ->
        Tickets.subscribe(workspace_id)
        Tickets.subscribe_comments(workspace_id, ticket_id)

      _ ->
        :ok
    end
  end

  @doc """
  Builds the ad-hoc task prompt for a planning session, or returns `nil`.
  """
  @spec ad_hoc_task(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def ad_hoc_task(%{assigns: %{role: "planning", ticket: ticket}}) when not is_nil(ticket) do
    PromptBuilder.planning_session_task(ticket)
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

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: nil
end
