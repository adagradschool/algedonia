defmodule AlgedoniaWeb.Api.TicketController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Tickets
  alias Algedonia.Tickets.Ticket

  def index(conn, params) do
    opts =
      [workspace_id: conn.assigns.workspace.id]
      |> maybe_put(:status, params["status"])
      |> maybe_put(:type, params["type"])
      |> maybe_put(:priority, parse_priority(params["priority"]))
      |> maybe_put(:assignee, params["assignee"])
      |> maybe_put(:sort_by, parse_sort_by(params["sort_by"]))
      |> maybe_put(:sort_order, parse_sort_order(params["sort_order"]))

    tickets = Tickets.list_tickets(opts)
    json(conn, %{tickets: Enum.map(tickets, &serialize_ticket/1)})
  end

  def show(conn, %{"id" => id}) do
    ticket = resolve_ticket(conn, id)
    json(conn, %{ticket: serialize_ticket(ticket)})
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(:not_found) |> json(%{error: "ticket not found"})
  end

  def create(conn, %{"ticket" => attrs}) do
    workspace = conn.assigns.workspace

    case Tickets.create_ticket_for_workspace(workspace, attrs) do
      {:ok, ticket} ->
        conn |> put_status(:created) |> json(%{ticket: serialize_ticket(ticket)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "missing ticket params"})
  end

  def update(conn, %{"id" => id} = params) do
    ticket = resolve_ticket(conn, id)
    attrs = params["ticket"] || %{}

    case Tickets.update_ticket(ticket, attrs) do
      {:ok, ticket} ->
        json(conn, %{ticket: serialize_ticket(ticket)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(:not_found) |> json(%{error: "ticket not found"})
  end

  def delete(conn, %{"id" => id}) do
    ticket = resolve_ticket(conn, id)

    case Tickets.delete_ticket(ticket) do
      {:ok, _} ->
        json(conn, %{ok: true})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(:not_found) |> json(%{error: "ticket not found"})
  end

  def export_markdown(conn, %{"id" => id}) do
    ticket = resolve_ticket(conn, id)
    comments = Tickets.list_comments(ticket.id)
    ticket = %{ticket | comments: comments}
    markdown = Tickets.export_markdown(ticket)
    workspace = conn.assigns.workspace
    filename = "#{workspace.prefix}-#{ticket.number}.md"

    conn
    |> put_resp_content_type("text/markdown")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, markdown)
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(:not_found) |> json(%{error: "ticket not found"})
  end

  defp resolve_ticket(conn, id) do
    workspace = conn.assigns.workspace

    case Integer.parse(id) do
      {number, ""} ->
        Tickets.get_ticket_by_number!(workspace.id, number)

      _ ->
        ticket = Tickets.get_ticket!(id)
        if ticket.workspace_id != workspace.id, do: raise(Ecto.NoResultsError, queryable: Ticket)
        ticket
    end
  end

  defp serialize_ticket(%Ticket{} = t) do
    %{
      id: t.id,
      number: t.number,
      title: t.title,
      description: t.description,
      status: t.status,
      type: t.type,
      priority: t.priority,
      assignee: t.assignee,
      coding_agent: t.coding_agent,
      acceptance_criteria: t.acceptance_criteria,
      rubric: t.rubric,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at
    }
  end

  defp format_errors(changeset), do: AlgedoniaWeb.Helpers.format_errors(changeset)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @valid_sort_fields ~w(priority inserted_at updated_at title number)a
  defp parse_sort_by(nil), do: nil

  defp parse_sort_by(field) when is_binary(field) do
    atom = String.to_existing_atom(field)
    if atom in @valid_sort_fields, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp parse_priority(nil), do: nil

  defp parse_priority(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} when n in 1..5 -> n
      _ -> nil
    end
  end

  defp parse_priority(_), do: nil

  defp parse_sort_order(nil), do: nil
  defp parse_sort_order("asc"), do: :asc
  defp parse_sort_order("desc"), do: :desc
  defp parse_sort_order(_), do: nil
end
