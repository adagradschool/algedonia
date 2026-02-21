defmodule Algedonia.Tickets do
  @moduledoc """
  Context for ticket management — CRUD, filtering, sorting, and PubSub broadcasts.
  """
  import Ecto.Query

  alias Algedonia.Repo
  alias Algedonia.Tickets.Ticket

  @topic "tickets"

  @doc """
  Lists tickets with optional filtering and sorting.

  ## Options

    * `:status` — filter by status atom
    * `:assignee` — filter by assignee string
    * `:sort_by` — field to sort by (default `:inserted_at`)
    * `:sort_order` — `:asc` or `:desc` (default `:desc`)

  """
  @spec list_tickets(keyword()) :: [Ticket.t()]
  def list_tickets(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_order = Keyword.get(opts, :sort_order, :desc)

    Ticket
    |> filter_by_status(opts[:status])
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
  Creates a ticket.
  """
  @spec create_ticket(map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def create_ticket(attrs) do
    %Ticket{}
    |> Ticket.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:ticket_created)
  end

  @doc """
  Updates a ticket.
  """
  @spec update_ticket(Ticket.t(), map()) :: {:ok, Ticket.t()} | {:error, Ecto.Changeset.t()}
  def update_ticket(%Ticket{} = ticket, attrs) do
    ticket
    |> Ticket.changeset(attrs)
    |> Repo.update()
    |> broadcast(:ticket_updated)
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

  defp filter_by_assignee(query, nil), do: query
  defp filter_by_assignee(query, ""), do: query
  defp filter_by_assignee(query, assignee), do: where(query, [t], t.assignee == ^assignee)
end
