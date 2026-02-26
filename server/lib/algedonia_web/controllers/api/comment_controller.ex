defmodule AlgedoniaWeb.Api.CommentController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Tickets
  alias Algedonia.Tickets.Comment

  def index(conn, %{"ticket_id" => ticket_id}) do
    ticket_id = resolve_ticket_id(conn, ticket_id)
    comments = Tickets.list_comments(ticket_id)
    json(conn, %{comments: Enum.map(comments, &serialize_comment/1)})
  end

  def create(conn, %{"ticket_id" => ticket_id, "comment" => attrs}) do
    ticket_id = resolve_ticket_id(conn, ticket_id)

    attrs = Map.put(attrs, "ticket_id", ticket_id)

    case Tickets.create_comment(attrs) do
      {:ok, comment} ->
        conn |> put_status(:created) |> json(%{comment: serialize_comment(comment)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "missing comment params"})
  end

  def update(conn, %{"id" => id, "comment" => attrs}) do
    comment = Tickets.get_comment!(id)
    verify_workspace!(conn, comment.ticket_id)

    case Tickets.update_comment(comment, attrs) do
      {:ok, comment} ->
        json(conn, %{comment: serialize_comment(comment)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(:not_found) |> json(%{error: "comment not found"})
  end

  def delete(conn, %{"id" => id}) do
    comment = Tickets.get_comment!(id)
    verify_workspace!(conn, comment.ticket_id)

    case Tickets.delete_comment(comment) do
      {:ok, _} ->
        json(conn, %{ok: true})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(:not_found) |> json(%{error: "comment not found"})
  end

  defp resolve_ticket_id(conn, id) do
    workspace = conn.assigns.workspace

    case Integer.parse(id) do
      {number, ""} ->
        ticket = Tickets.get_ticket_by_number!(workspace.id, number)
        ticket.id

      _ ->
        id
    end
  end

  defp verify_workspace!(conn, ticket_id) do
    ticket = Tickets.get_ticket!(ticket_id)
    workspace = conn.assigns.workspace

    if ticket.workspace_id != workspace.id do
      raise Ecto.NoResultsError, queryable: Algedonia.Tickets.Ticket
    end
  end

  defp serialize_comment(%Comment{} = c) do
    base = %{
      id: c.id,
      author: c.author,
      body: c.body,
      ticket_id: c.ticket_id,
      parent_id: c.parent_id,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }

    case c.replies do
      %Ecto.Association.NotLoaded{} -> base
      replies -> Map.put(base, :replies, Enum.map(replies, &serialize_comment/1))
    end
  end

  defp format_errors(changeset), do: AlgedoniaWeb.Helpers.format_errors(changeset)
end
