defmodule Algedonia.Tickets do
  @moduledoc """
  Context for ticket management — CRUD, filtering, sorting, and PubSub broadcasts.
  """
  import Ecto.Query

  alias Algedonia.Repo
  alias Algedonia.Tickets.{Comment, Ticket}

  @topic "tickets"
  @display_statuses [:backlog, :planning, :in_progress, :halted, :completed, :archived]

  @doc """
  Returns ticket statuses in UI display order.
  """
  @spec display_statuses() :: [atom()]
  def display_statuses, do: @display_statuses

  @doc """
  Lists tickets with optional filtering and sorting.

  ## Options

    * `:status` — filter by status atom
    * `:type` — filter by type atom (feature, bug, chore, spike)
    * `:priority` — filter by priority integer (1-5)
    * `:assignee` — filter by assignee string
    * `:sort_by` — field to sort by (default `:inserted_at`)
    * `:sort_order` — `:asc` or `:desc` (default `:desc`)

  """
  @spec list_tickets(keyword()) :: [Ticket.t()]
  def list_tickets(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_order = Keyword.get(opts, :sort_order, :desc)
    workspace_id = Keyword.get(opts, :workspace_id)

    Ticket
    |> filter_by_workspace(workspace_id)
    |> filter_by_status(opts[:status])
    |> filter_by_type(opts[:type])
    |> filter_by_priority(opts[:priority])
    |> filter_by_assignee(opts[:assignee])
    |> order_by([t], [{^sort_order, field(t, ^sort_by)}])
    |> Repo.all()
  end

  @doc """
  Lists tickets grouped by status. Returns a map of `%{status => [ticket]}`.
  """
  @spec list_tickets_by_status(keyword()) :: %{atom() => [Ticket.t()]}
  def list_tickets_by_status(opts \\ []) do
    list_tickets(Keyword.put_new(opts, :sort_by, :priority))
    |> Enum.group_by(& &1.status)
  end

  @doc """
  Gets a single ticket. Raises `Ecto.NoResultsError` if not found.
  """
  @spec get_ticket!(binary()) :: Ticket.t()
  def get_ticket!(id), do: Repo.get!(Ticket, id)

  @doc """
  Resolves a ticket by reference inside a workspace.

  Accepts a UUID or a numeric ticket number.
  """
  @spec get_ticket_by_ref!(binary(), binary()) :: Ticket.t()
  def get_ticket_by_ref!(workspace_id, ref) when is_binary(ref) do
    case Integer.parse(ref) do
      {number, ""} -> get_ticket_by_number!(workspace_id, number)
      _ -> get_ticket!(ref)
    end
  end

  @doc """
  Gets a ticket by workspace ID and ticket number. Raises if not found.
  """
  @spec get_ticket_by_number!(binary(), integer()) :: Ticket.t()
  def get_ticket_by_number!(workspace_id, number) do
    Repo.get_by!(Ticket, workspace_id: workspace_id, number: number)
  end

  @doc """
  Creates a ticket.
  """
  @spec create_ticket(map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def create_ticket(attrs) do
    %Ticket{}
    |> Ticket.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:ticket_created)
  end

  def create_ticket_for_workspace(%Algedonia.Workspaces.Workspace{} = workspace, attrs) do
    number = Algedonia.Workspaces.next_ticket_number!(workspace)

    %Ticket{}
    |> Ticket.changeset(
      attrs
      |> Map.put("workspace_id", workspace.id)
      |> Map.put("number", number)
    )
    |> Repo.insert()
    |> broadcast(:ticket_created)
  end

  @doc """
  Updates a ticket.

  ## Options

    * `:skip_hooks` — when `true`, does not fire transition hooks (default `false`)
  """
  @spec update_ticket(Ticket.t(), map(), keyword()) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def update_ticket(%Ticket{} = ticket, attrs, opts \\ []) do
    old_status = ticket.status

    result =
      ticket
      |> Ticket.changeset(attrs)
      |> Repo.update()
      |> broadcast(:ticket_updated)

    with {:ok, updated} <- result,
         false <- Keyword.get(opts, :skip_hooks, false) do
      maybe_fire_hooks(ticket, old_status, updated)
    end

    result
  end

  defp maybe_fire_hooks(ticket, old_status, updated) do
    new_status = updated.status

    if old_status != new_status && !(old_status == :halted && new_status == :halted) do
      Algedonia.HookExecutor.fire_hooks(ticket.workspace_id, updated, old_status, new_status)
    end
  end

  @doc """
  Deletes a ticket.
  """
  @spec delete_ticket(Ticket.t()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def delete_ticket(%Ticket{} = ticket) do
    Repo.delete(ticket)
    |> broadcast(:ticket_deleted)
  end

  @doc """
  Persists overview content for a ticket.
  """
  @spec update_overview(Ticket.t(), String.t()) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def update_overview(%Ticket{} = ticket, content) do
    ticket
    |> Ticket.changeset(%{overview: content})
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking ticket changes.
  """
  @spec change_ticket(Ticket.t(), map()) :: Ecto.Changeset.t()
  def change_ticket(%Ticket{} = ticket, attrs \\ %{}) do
    Ticket.changeset(ticket, attrs)
  end

  @doc """
  Subscribes the caller to ticket change notifications.
  """
  @spec subscribe :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, @topic)
  end

  defp broadcast({:ok, ticket} = result, event) do
    Phoenix.PubSub.broadcast(Algedonia.PubSub, @topic, {event, ticket})
    result
  end

  defp broadcast({:error, _} = result, _event), do: result

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, ""), do: query
  defp filter_by_status(query, status), do: where(query, [t], t.status == ^status)

  defp filter_by_workspace(query, nil), do: query

  defp filter_by_workspace(query, workspace_id),
    do: where(query, [t], t.workspace_id == ^workspace_id)

  # -- Comments --

  @doc """
  Lists comments for a ticket, threaded. Returns top-level comments with
  replies preloaded one level deep, ordered by insertion time.
  """
  @spec list_comments(binary()) :: [Comment.t()]
  def list_comments(ticket_id) do
    replies_query = from(c in Comment, order_by: [asc: c.inserted_at])

    Comment
    |> where([c], c.ticket_id == ^ticket_id and is_nil(c.parent_id))
    |> order_by([c], asc: c.inserted_at)
    |> preload(replies: ^replies_query)
    |> Repo.all()
  end

  @doc """
  Gets a single comment. Raises `Ecto.NoResultsError` if not found.
  """
  @spec get_comment!(binary()) :: Comment.t()
  def get_comment!(id), do: Repo.get!(Comment, id)

  @doc """
  Creates a comment on a ticket.
  """
  @spec create_comment(map()) :: {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def create_comment(attrs) do
    %Comment{}
    |> Comment.changeset(attrs)
    |> Repo.insert()
    |> broadcast_comment()
  end

  @doc """
  Updates a comment's body.
  """
  @spec update_comment(Comment.t(), map()) :: {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def update_comment(%Comment{} = comment, attrs) do
    comment
    |> Comment.changeset(attrs)
    |> Repo.update()
    |> broadcast_comment(:comment_updated)
  end

  @doc """
  Deletes a comment and its replies.
  """
  @spec delete_comment(Comment.t()) :: {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def delete_comment(%Comment{} = comment) do
    from(c in Comment, where: c.parent_id == ^comment.id) |> Repo.delete_all()

    comment
    |> Repo.delete()
    |> broadcast_comment(:comment_deleted)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking comment changes.
  """
  @spec change_comment(Comment.t(), map()) :: Ecto.Changeset.t()
  def change_comment(%Comment{} = comment, attrs \\ %{}) do
    Comment.changeset(comment, attrs)
  end

  @doc """
  Subscribes the caller to comment notifications for a specific ticket.
  """
  @spec subscribe_comments(binary()) :: :ok | {:error, term()}
  def subscribe_comments(ticket_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, "ticket:#{ticket_id}")
  end

  defp broadcast_comment(result), do: broadcast_comment(result, :comment_created)

  defp broadcast_comment({:ok, comment} = result, event) do
    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      "ticket:#{comment.ticket_id}",
      {event, comment}
    )

    result
  end

  defp broadcast_comment({:error, _} = result, _event), do: result

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, ""), do: query
  defp filter_by_type(query, type), do: where(query, [t], t.type == ^type)

  defp filter_by_priority(query, nil), do: query
  defp filter_by_priority(query, priority), do: where(query, [t], t.priority == ^priority)

  defp filter_by_assignee(query, nil), do: query
  defp filter_by_assignee(query, ""), do: query
  defp filter_by_assignee(query, assignee), do: where(query, [t], t.assignee == ^assignee)

  @doc """
  Resets a ticket by removing all loops/steps and setting status back to backlog.
  """
  @spec reset_ticket(Ticket.t()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def reset_ticket(%Ticket{} = ticket) do
    Algedonia.Loops.delete_loops_for_ticket(ticket.id)
    update_ticket(ticket, %{status: :backlog}, skip_hooks: true)
  end

  # -- Markdown export (delegated) --

  defdelegate export_markdown(ticket), to: Algedonia.Tickets.MarkdownExport, as: :render

  # -- Planning workflow (delegated) --

  defdelegate start_work(ticket), to: Algedonia.Tickets.Planning
  defdelegate start_planning(ticket), to: Algedonia.Tickets.Planning

  # -- Search (delegated) --

  defdelegate search_tickets_grouped(opts), to: Algedonia.Tickets.Search
end
