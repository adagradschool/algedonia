defmodule Algedonia.Tickets do
  @moduledoc """
  Context for ticket management — CRUD, filtering, sorting, and PubSub broadcasts.
  """
  import Ecto.Changeset
  import Ecto.Query

  require Logger

  alias Algedonia.PubSub.Topics
  alias Algedonia.Repo
  alias Algedonia.Skills.Error
  alias Algedonia.Tickets.{Comment, QueueEntry, Ticket}
  alias Algedonia.Tickets.Planning
  alias Algedonia.Workspaces
  alias Algedonia.Workspaces.Workspace

  @display_statuses [
    :backlog,
    :planning,
    :in_progress,
    :in_review,
    :halted,
    :completed,
    :archived
  ]

  @doc """
  Returns ticket statuses in UI display order.
  """
  @spec display_statuses() :: [atom()]
  def display_statuses, do: @display_statuses

  @doc """
  Returns the human-readable ticket code using the workspace prefix when available.
  """
  @spec ticket_code(
          %{number: integer()} | %{id: String.t()},
          %{prefix: String.t()} | String.t() | nil
        ) ::
          String.t()
  def ticket_code(%{number: number}, %{prefix: prefix}) when is_integer(number),
    do: "#{ticket_prefix(prefix)}-#{number}"

  def ticket_code(%{number: number}, prefix) when is_integer(number),
    do: "#{ticket_prefix(prefix)}-#{number}"

  def ticket_code(%{id: id}, _workspace_or_prefix), do: id

  @doc """
  Returns the daemon payload fields required to create a deterministic ticket worktree branch.
  """
  @spec worktree_payload(
          %{type: atom() | String.t()},
          %{prefix: String.t(), worktree_bootstrap_script: String.t() | nil} | String.t() | nil
        ) ::
          map()
  def worktree_payload(ticket, workspace_or_prefix) do
    %{
      "ticket_type" => ticket_type(ticket),
      "ticket_code" => ticket_code(ticket, workspace_or_prefix),
      "worktree_bootstrap_script" => worktree_bootstrap_script(workspace_or_prefix)
    }
  end

  @doc """
  Returns the deterministic worktree branch for a ticket.
  """
  @spec worktree_branch_name(
          %{type: atom() | String.t()},
          %{prefix: String.t()} | String.t() | nil
        ) :: String.t()
  def worktree_branch_name(ticket, workspace_or_prefix) do
    "#{ticket_type(ticket)}/#{ticket_code(ticket, workspace_or_prefix)}"
  end

  defp worktree_bootstrap_script(%{worktree_bootstrap_script: script}), do: script
  defp worktree_bootstrap_script(_), do: nil

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
  @spec get_ticket!(Algedonia.Types.id()) :: Ticket.t()
  def get_ticket!(id), do: Repo.get!(Ticket, id)

  @doc """
  Resolves a ticket by reference inside a workspace.

  Accepts a UUID or a numeric ticket number.
  """
  @spec get_ticket_by_ref!(Algedonia.Types.id(), binary()) :: Ticket.t()
  def get_ticket_by_ref!(workspace_id, ref) when is_binary(ref) do
    case Integer.parse(ref) do
      {number, ""} -> get_ticket_by_number!(workspace_id, number)
      _ -> get_ticket!(ref)
    end
  end

  @doc """
  Gets a ticket by workspace ID and ticket number. Raises if not found.
  """
  @spec get_ticket_by_number!(Algedonia.Types.id(), integer()) :: Ticket.t()
  def get_ticket_by_number!(workspace_id, number) do
    Repo.get_by!(Ticket, workspace_id: workspace_id, number: number)
  end

  @doc """
  Gets tickets by a list of IDs. Returns them in the order found.
  """
  @spec get_tickets_by_ids([Algedonia.Types.id()]) :: [Ticket.t()]
  def get_tickets_by_ids([]), do: []

  def get_tickets_by_ids(ids) when is_list(ids) do
    import Ecto.Query
    Ticket |> where([t], t.id in ^ids) |> Repo.all()
  end

  @doc """
  Returns workspace-scoped assignee options as `{label, value}` tuples.
  """
  @spec list_assignee_options(Algedonia.Types.id() | nil) :: [{String.t(), String.t()}]
  def list_assignee_options(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> Workspaces.list_members()
    |> Enum.map(&member_assignee_option/1)
    |> Enum.reject(fn {label, _value} -> label == "" end)
    |> Enum.uniq_by(fn {label, _value} -> label end)
  end

  def list_assignee_options(_workspace_id), do: []

  @doc """
  Creates a ticket.
  """
  @spec create_ticket(map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def create_ticket(attrs) do
    attrs
    |> ticket_create_changeset()
    |> insert_ticket_with_queue()
    |> broadcast(:ticket_created)
  end

  @spec create_ticket_for_workspace(Workspace.t(), map()) ::
          {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def create_ticket_for_workspace(%Algedonia.Workspaces.Workspace{} = workspace, attrs) do
    number = Algedonia.Workspaces.next_ticket_number!(workspace)

    result =
      attrs
      |> Map.put("workspace_id", workspace.id)
      |> Map.put("number", number)
      |> ticket_create_changeset()
      |> insert_ticket_with_queue()
      |> broadcast(:ticket_created)

    with {:ok, ticket} <- result do
      Algedonia.Tracker.notify_create(workspace, Map.from_struct(ticket))
    end

    result
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
    changeset = ticket_changeset(ticket, attrs, ticket.id)

    case Repo.update(changeset) do
      {:ok, updated} ->
        maybe_apply_status_loop_lifecycle(old_status, updated)
        result = broadcast({:ok, updated}, :ticket_updated)

        unless Keyword.get(opts, :skip_hooks, false) do
          maybe_fire_hooks(ticket, old_status, updated)
        end

        notify_tracker_update(ticket, updated, old_status)
        result

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns persisted queue state for the given workspace.
  """
  @spec list_queue(Algedonia.Types.id()) :: [
          %{
            ticket_id: Algedonia.Types.id(),
            position: integer(),
            status: String.t(),
            dispatchable: boolean()
          }
        ]
  def list_queue(workspace_id) when is_binary(workspace_id) do
    queue_entries =
      Repo.all(
        from q in QueueEntry,
          where: q.workspace_id == ^workspace_id and not is_nil(q.ticket_id),
          order_by: [asc: q.position, asc: q.inserted_at],
          select: %{ticket_id: q.ticket_id, position: q.position, status: q.status}
      )

    ticket_ids = Enum.map(queue_entries, & &1.ticket_id)
    queue_state = queue_state_for_tickets(workspace_id, ticket_ids)

    Enum.map(queue_entries, fn entry ->
      state = Map.get(queue_state, entry.ticket_id, %{dispatchable: false})
      Map.put(entry, :dispatchable, state.dispatchable)
    end)
  end

  @doc """
  Reorders queue positions for all ticket queue entries in a workspace.
  """
  @spec reorder_queue(Algedonia.Types.id(), [Algedonia.Types.id()]) ::
          {:ok,
           [
             %{
               ticket_id: Algedonia.Types.id(),
               position: integer(),
               status: String.t(),
               dispatchable: boolean()
             }
           ]}
          | {:error, Ecto.Changeset.t()}
  def reorder_queue(workspace_id, ordered_ticket_ids)
      when is_binary(workspace_id) and is_list(ordered_ticket_ids) do
    ordered_ticket_ids = Enum.map(ordered_ticket_ids, &to_string/1)

    queue_entries =
      Repo.all(
        from q in QueueEntry,
          where: q.workspace_id == ^workspace_id and not is_nil(q.ticket_id),
          select: q,
          order_by: [asc: q.position, asc: q.inserted_at]
      )

    queued_ticket_ids = Enum.map(queue_entries, & &1.ticket_id)

    with :ok <- validate_reorder_ticket_ids(ordered_ticket_ids, queued_ticket_ids),
         {:ok, _} <- persist_reorder(queue_entries, ordered_ticket_ids) do
      {:ok, list_queue(workspace_id)}
    end
  end

  defp ticket_prefix(%{prefix: prefix}), do: ticket_prefix(prefix)
  defp ticket_prefix(prefix) when is_binary(prefix) and prefix != "", do: prefix
  defp ticket_prefix(_), do: "AG"

  defp ticket_type(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp ticket_type(%{type: type}) when is_binary(type), do: String.downcase(type)
  defp ticket_type(_), do: ""

  @doc """
  Returns queue metadata keyed by ticket ID for the given ticket IDs.
  """
  @spec queue_state_for_tickets(Algedonia.Types.id(), [Algedonia.Types.id()]) ::
          %{
            optional(Algedonia.Types.id()) => %{
              queue_position: integer() | nil,
              queue_status: String.t() | nil,
              dispatchable: boolean()
            }
          }
  def queue_state_for_tickets(workspace_id, ticket_ids)
      when is_binary(workspace_id) and is_list(ticket_ids) do
    ticket_ids =
      ticket_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if ticket_ids == [] do
      %{}
    else
      queue_map =
        Repo.all(
          from q in QueueEntry,
            where: q.workspace_id == ^workspace_id and q.ticket_id in ^ticket_ids,
            select: {q.ticket_id, %{queue_position: q.position, queue_status: q.status}}
        )
        |> Map.new()

      blocker_map =
        Repo.all(
          from t in Ticket,
            where: t.workspace_id == ^workspace_id and t.id in ^ticket_ids,
            select: {t.id, t.blocked_by}
        )
        |> Map.new()

      blocker_status_map =
        blocker_map
        |> Map.values()
        |> List.flatten()
        |> Enum.uniq()
        |> blocker_statuses(workspace_id)

      Enum.reduce(ticket_ids, %{}, fn ticket_id, acc ->
        blockers = Map.get(blocker_map, ticket_id, [])
        queue_state = Map.get(queue_map, ticket_id, %{queue_position: nil, queue_status: nil})

        Map.put(
          acc,
          ticket_id,
          Map.put(queue_state, :dispatchable, blockers_completed?(blockers, blocker_status_map))
        )
      end)
    end
  end

  defp maybe_apply_status_loop_lifecycle(old_status, updated) do
    with_workspace_scope(updated.workspace_id, fn ->
      new_status = updated.status

      cond do
        old_status != :in_progress and new_status == :in_progress ->
          maybe_ensure_work_loop(updated)

        old_status == :in_progress and new_status == :in_review ->
          Algedonia.ReviewLoop.start_review(updated)

        old_status == :in_progress and new_status in [:backlog, :planning] ->
          _ = Algedonia.Loops.delete_loops_for_ticket(updated.id)
          :ok

        true ->
          :ok
      end
    end)
  end

  defp maybe_ensure_work_loop(ticket) do
    case Planning.ensure_work_loop(ticket) do
      {:ok, _loop_id} ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to ensure task loop for ticket #{ticket.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp with_workspace_scope(workspace_id, fun)
       when is_binary(workspace_id) and is_function(fun, 0) do
    previous_workspace = Algedonia.TenantScope.get_workspace()
    Algedonia.TenantScope.put_workspace(workspace_id)

    try do
      fun.()
    after
      case previous_workspace do
        wid when is_binary(wid) -> Algedonia.TenantScope.put_workspace(wid)
        _ -> Algedonia.TenantScope.clear_workspace()
      end
    end
  end

  defp with_workspace_scope(_workspace_id, fun) when is_function(fun, 0), do: fun.()

  defp notify_tracker_update(ticket, updated, old_status) do
    workspace = Algedonia.Workspaces.get_workspace(ticket.workspace_id)

    if workspace do
      if old_status != updated.status do
        Algedonia.Tracker.notify_status(workspace, updated.id, updated.status)
      end

      Algedonia.Tracker.notify_update(workspace, updated.id, Map.from_struct(updated))
    end
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
    result =
      Repo.delete(ticket)
      |> broadcast(:ticket_deleted)

    with {:ok, deleted} <- result do
      workspace = Algedonia.Workspaces.get_workspace(deleted.workspace_id)
      if workspace, do: Algedonia.Tracker.notify_delete(workspace, deleted.id)
    end

    result
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
    ticket_changeset(ticket, attrs, ticket.id)
  end

  @doc """
  Subscribes the caller to ticket change notifications.
  """
  @spec subscribe(Algedonia.Types.id()) :: :ok | {:error, term()}
  def subscribe(workspace_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, Topics.tickets(workspace_id))
  end

  defp broadcast({:ok, ticket} = result, event) do
    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.tickets(ticket.workspace_id),
      {event, ticket}
    )

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
  @spec list_comments(Algedonia.Types.id()) :: [Comment.t()]
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
  @spec get_comment!(Algedonia.Types.id()) :: Comment.t()
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
  @spec subscribe_comments(Algedonia.Types.id(), Algedonia.Types.id()) :: :ok | {:error, term()}
  def subscribe_comments(workspace_id, ticket_id) do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, Topics.ticket(workspace_id, ticket_id))
  end

  defp broadcast_comment(result), do: broadcast_comment(result, :comment_created)

  defp broadcast_comment({:ok, comment} = result, event) do
    workspace_id = ticket_workspace_id(comment.ticket_id)

    Phoenix.PubSub.broadcast(
      Algedonia.PubSub,
      Topics.ticket(workspace_id, comment.ticket_id),
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

  @doc """
  Resolves the effective land mode for a ticket using deterministic precedence:
  ticket override -> workspace default -> system fallback `:review_gate`.
  """
  @spec resolve_land_mode(Ticket.t(), Workspace.t() | nil) :: :review_gate | :auto_land
  def resolve_land_mode(%Ticket{land_mode: mode}, _workspace)
      when mode in [:review_gate, :auto_land] do
    mode
  end

  def resolve_land_mode(_ticket, %Workspace{defaults: %{"land_mode" => "auto_land"}}),
    do: :auto_land

  def resolve_land_mode(_ticket, %Workspace{defaults: %{"land_mode" => "review_gate"}}),
    do: :review_gate

  def resolve_land_mode(_ticket, _workspace), do: :review_gate

  # -- Markdown export (delegated) --

  @spec export_markdown(Ticket.t()) :: String.t()
  defdelegate export_markdown(ticket), to: Algedonia.Tickets.MarkdownExport, as: :render

  # -- Planning workflow (delegated) --

  @spec start_work(Ticket.t(), keyword()) ::
          {:ok, Algedonia.Types.id()} | {:error, atom() | {:invalid_checker_config, [Error.t()]}}
  def start_work(ticket, opts \\ []), do: Planning.start_work(ticket, opts)
  @spec start_planning(Ticket.t()) :: {:ok, Ticket.t()} | {:error, atom() | Ecto.Changeset.t()}
  defdelegate start_planning(ticket), to: Algedonia.Tickets.Planning
  defdelegate start_planning_work(ticket), to: Algedonia.Tickets.Planning

  # -- Search (delegated) --

  @spec search_tickets_grouped(keyword()) :: %{grouped: map(), count: integer()}
  defdelegate search_tickets_grouped(opts), to: Algedonia.Tickets.Search

  defp ticket_workspace_id(ticket_id) do
    Ticket
    |> where([t], t.id == ^ticket_id)
    |> select([t], t.workspace_id)
    |> Repo.one()
  end

  defp ticket_create_changeset(attrs) do
    %Ticket{}
    |> ticket_changeset(attrs, nil)
  end

  defp ticket_changeset(ticket, attrs, ticket_id) do
    ticket
    |> Ticket.changeset(attrs)
    |> normalize_assignee()
    |> validate_assignee_membership()
    |> validate_blocked_by_constraints(ticket_id)
  end

  defp insert_ticket_with_queue(changeset) do
    workspace_id = get_field(changeset, :workspace_id)

    with_workspace_scope(workspace_id, fn ->
      Repo.transaction(fn -> insert_ticket_and_queue(changeset) end)
      |> normalize_ticket_insert_result(changeset)
    end)
  end

  defp insert_ticket_and_queue(changeset) do
    case Repo.insert(changeset) do
      {:ok, ticket} ->
        insert_queue_entry_or_rollback(ticket)

      {:error, ticket_changeset} ->
        Repo.rollback({:ticket, ticket_changeset})
    end
  end

  defp insert_queue_entry_or_rollback(ticket) do
    case insert_queue_entry(Repo, ticket) do
      {:ok, _queue_entry} -> ticket
      {:error, reason} -> Repo.rollback({:queue_entry, reason})
    end
  end

  defp normalize_ticket_insert_result({:ok, ticket}, _changeset), do: {:ok, ticket}

  defp normalize_ticket_insert_result({:error, {:ticket, ticket_changeset}}, _changeset) do
    {:error, ticket_changeset}
  end

  defp normalize_ticket_insert_result({:error, {:queue_entry, _reason}}, changeset) do
    {:error, add_error(changeset, :base, "queue entry persistence failed")}
  end

  defp insert_queue_entry(repo, %Ticket{} = ticket) do
    max_position =
      repo.one(
        from q in QueueEntry,
          where: q.workspace_id == ^ticket.workspace_id,
          select: fragment("COALESCE(MAX(?), -1)", q.position)
      ) || -1

    attrs = %{
      workspace_id: ticket.workspace_id,
      ticket_id: ticket.id,
      status: "queued",
      position: max_position + 1
    }

    %QueueEntry{}
    |> QueueEntry.changeset(attrs)
    |> repo.insert()
  end

  defp validate_reorder_ticket_ids(ordered_ticket_ids, queued_ticket_ids) do
    cond do
      Enum.uniq(ordered_ticket_ids) != ordered_ticket_ids ->
        {:error, add_error(change(%Ticket{}), :ticket_ids, "contains duplicate ticket ids")}

      MapSet.new(ordered_ticket_ids) != MapSet.new(queued_ticket_ids) ->
        {:error,
         add_error(
           change(%Ticket{}),
           :ticket_ids,
           "must include each queued ticket id exactly once"
         )}

      true ->
        :ok
    end
  end

  defp persist_reorder(queue_entries, ordered_ticket_ids) do
    by_ticket_id = Map.new(queue_entries, &{&1.ticket_id, &1})

    Repo.transaction(fn ->
      Enum.with_index(ordered_ticket_ids)
      |> Enum.each(&update_queue_position(by_ticket_id, &1))
    end)
    |> case do
      {:ok, _} = ok ->
        ok

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} ->
        {:error,
         add_error(
           change(%Ticket{}),
           :ticket_ids,
           "failed to persist queue order: #{inspect(reason)}"
         )}
    end
  end

  defp update_queue_position(by_ticket_id, {ticket_id, position}) do
    queue_entry = Map.fetch!(by_ticket_id, ticket_id)

    case queue_entry |> QueueEntry.changeset(%{position: position}) |> Repo.update() do
      {:ok, _updated} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp blocker_statuses([], _workspace_id), do: %{}

  defp blocker_statuses(blocker_ids, workspace_id) do
    Repo.all(
      from t in Ticket,
        where: t.workspace_id == ^workspace_id and t.id in ^blocker_ids,
        select: {t.id, t.status}
    )
    |> Map.new()
  end

  defp blockers_completed?(blocker_ids, blocker_status_map) do
    Enum.all?(blocker_ids, fn blocker_id ->
      Map.get(blocker_status_map, blocker_id) == :completed
    end)
  end

  defp validate_blocked_by_constraints(changeset, ticket_id) do
    blocked_by = get_field(changeset, :blocked_by) || []
    workspace_id = get_field(changeset, :workspace_id)

    changeset
    |> maybe_validate_blocker_references(workspace_id, blocked_by)
    |> maybe_validate_blocker_cycle(workspace_id, ticket_id, blocked_by)
  end

  defp maybe_validate_blocker_references(changeset, workspace_id, blocked_by)
       when not is_binary(workspace_id) or blocked_by == [] do
    changeset
  end

  defp maybe_validate_blocker_references(changeset, _workspace_id, _blocked_by)
       when not changeset.valid? do
    changeset
  end

  defp maybe_validate_blocker_references(changeset, workspace_id, blocked_by) do
    existing_blockers =
      Repo.all(
        from t in Ticket,
          where: t.workspace_id == ^workspace_id and t.id in ^blocked_by,
          select: t.id
      )

    if blocked_by -- existing_blockers == [] do
      changeset
    else
      add_error(changeset, :blocked_by, "contains invalid blocker references")
    end
  end

  defp normalize_assignee(changeset) do
    update_change(changeset, :assignee, fn
      nil ->
        nil

      assignee when is_binary(assignee) ->
        case String.trim(assignee) do
          "" -> nil
          trimmed -> trimmed
        end

      assignee ->
        assignee
    end)
  end

  defp validate_assignee_membership(changeset) do
    case fetch_change(changeset, :assignee) do
      :error ->
        changeset

      {:ok, nil} ->
        changeset

      {:ok, assignee} ->
        workspace_id = get_field(changeset, :workspace_id)

        if is_binary(workspace_id) and assignee in assignee_values_for_workspace(workspace_id) do
          changeset
        else
          add_error(changeset, :assignee, "must be a workspace member")
        end
    end
  end

  defp assignee_values_for_workspace(workspace_id) do
    workspace_id
    |> list_assignee_options()
    |> Enum.map(fn {_label, value} -> value end)
  end

  defp member_assignee_option(user) do
    label = member_assignee_label(user)
    {label, label}
  end

  defp member_assignee_label(%{name: name, github_username: github_username, email: email}) do
    cond do
      is_binary(name) and String.trim(name) != "" ->
        String.trim(name)

      is_binary(github_username) and String.trim(github_username) != "" ->
        String.trim(github_username)

      is_binary(email) and String.trim(email) != "" ->
        String.trim(email)

      true ->
        ""
    end
  end

  defp maybe_validate_blocker_cycle(changeset, workspace_id, ticket_id, blocked_by) do
    if changeset.valid? and is_binary(workspace_id) and is_binary(ticket_id) and blocked_by != [] and
         creates_dependency_cycle?(workspace_id, ticket_id, blocked_by) do
      add_error(changeset, :blocked_by, "creates a dependency cycle")
    else
      changeset
    end
  end

  defp creates_dependency_cycle?(workspace_id, ticket_id, blocked_by) do
    dependency_graph =
      Repo.all(
        from t in Ticket,
          where: t.workspace_id == ^workspace_id,
          select: {t.id, t.blocked_by}
      )
      |> Map.new()
      |> Map.put(ticket_id, blocked_by)

    Enum.any?(blocked_by, fn blocker_id ->
      blocker_id == ticket_id or reachable?(blocker_id, ticket_id, dependency_graph, MapSet.new())
    end)
  end

  defp reachable?(current, target, graph, visited) do
    cond do
      current == target ->
        true

      MapSet.member?(visited, current) ->
        false

      true ->
        visited = MapSet.put(visited, current)
        blockers = Map.get(graph, current, [])
        Enum.any?(blockers, &reachable?(&1, target, graph, visited))
    end
  end
end
