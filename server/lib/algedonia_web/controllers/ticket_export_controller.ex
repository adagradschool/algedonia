defmodule AlgedoniaWeb.TicketExportController do
  @moduledoc """
  Browser-accessible ticket export endpoint (session auth).
  """
  use AlgedoniaWeb, :controller

  alias Algedonia.Tickets

  def export_markdown(conn, %{"ticket_ref" => ref}) do
    workspace = conn.assigns.current_workspace
    ticket = Tickets.get_ticket_by_ref!(workspace.id, ref)
    comments = Tickets.list_comments(ticket.id)
    ticket = %{ticket | comments: comments}
    markdown = Tickets.export_markdown(ticket)
    filename = "#{workspace.prefix}-#{ticket.number}.md"

    conn
    |> put_resp_content_type("text/markdown")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, markdown)
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(:not_found) |> json(%{error: "ticket not found"})
  end
end
