defmodule Algedonia.Tickets.Search do
  @moduledoc """
  Text search and grouped filtering for tickets.
  """
  alias Algedonia.Tickets

  @doc """
  Searches and groups tickets by status with optional text filtering.

  Returns `%{grouped: %{status => [ticket]}, count: integer}`.

  ## Options

    * `:status` — filter by status atom
    * `:assignee` — filter by assignee string
    * `:sort_by` — field to sort by (default `:priority`)
    * `:sort_order` — `:asc` or `:desc` (default `:asc`)
    * `:workspace_id` — scope to workspace
    * `:query` — text search string
    * `:prefix` — workspace prefix for ticket code search
  """
  @spec search_tickets_grouped(keyword()) :: %{grouped: map(), count: integer()}
  def search_tickets_grouped(opts) do
    query = Keyword.get(opts, :query)
    prefix = Keyword.get(opts, :prefix, "AG")

    grouped =
      opts
      |> Tickets.list_tickets_by_status()
      |> filter_grouped_by_query(query, prefix)

    count =
      grouped
      |> Map.take([:planning, :in_progress, :backlog, :halted])
      |> Map.values()
      |> List.flatten()
      |> length()

    %{grouped: grouped, count: count}
  end

  defp filter_grouped_by_query(grouped, nil, _prefix), do: grouped

  defp filter_grouped_by_query(grouped, query, prefix) do
    terms =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    Map.new(grouped, fn {status, tickets} ->
      {status, Enum.filter(tickets, &ticket_matches_query?(&1, terms, prefix))}
    end)
  end

  defp ticket_matches_query?(ticket, terms, prefix) do
    haystack =
      [
        ticket.title,
        ticket.description,
        ticket.assignee,
        ticket_search_code(ticket, prefix),
        AlgedoniaWeb.Helpers.short_id(ticket.id)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.all?(terms, &String.contains?(haystack, &1))
  end

  defp ticket_search_code(%{number: number}, prefix) when is_integer(number),
    do: "#{prefix}-#{number}"

  defp ticket_search_code(%{id: id}, _prefix),
    do: AlgedoniaWeb.Helpers.short_id(id)
end
