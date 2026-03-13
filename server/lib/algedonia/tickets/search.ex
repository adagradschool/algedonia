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
    * `:sort_preferences` — per-status field/direction preferences
    * `:workspace_id` — scope to workspace
    * `:query` — text search string
    * `:prefix` — workspace prefix for ticket code search
  """
  @spec search_tickets_grouped(keyword()) :: %{grouped: map(), count: integer()}
  def search_tickets_grouped(opts) do
    query = Keyword.get(opts, :query)
    prefix = Keyword.get(opts, :prefix, "AG")
    sort_preferences = Keyword.get(opts, :sort_preferences, %{})

    grouped =
      opts
      |> grouped_tickets()
      |> filter_grouped_by_query(query, prefix)
      |> sort_grouped(sort_preferences)

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

  defp grouped_tickets(opts) do
    opts
    |> Keyword.drop([:sort_by, :sort_order, :sort_preferences])
    |> Tickets.list_tickets()
    |> Enum.group_by(& &1.status)
  end

  defp sort_grouped(grouped, sort_preferences) do
    Map.new(grouped, fn {status, tickets} ->
      preference = status_sort_preference(sort_preferences, status)

      {status,
       Enum.sort_by(tickets, &ticket_sort_key(&1, preference.sort_by), preference.sort_order)}
    end)
  end

  defp status_sort_preference(sort_preferences, :completed) do
    Map.get(sort_preferences, :completed) || Map.get(sort_preferences, "completed") ||
      %{
        sort_by: :updated_at,
        sort_order: :desc
      }
  end

  defp status_sort_preference(sort_preferences, status) do
    Map.get(sort_preferences, status) || Map.get(sort_preferences, to_string(status)) ||
      %{
        sort_by: :priority,
        sort_order: :asc
      }
  end

  defp ticket_sort_key(ticket, :inserted_at),
    do: {sortable_datetime(ticket.inserted_at), ticket.number || 0, ticket.id}

  defp ticket_sort_key(ticket, :updated_at),
    do: {sortable_datetime(ticket.updated_at), ticket.number || 0, ticket.id}

  defp ticket_sort_key(ticket, :title),
    do: {String.downcase(ticket.title || ""), ticket.number || 0, ticket.id}

  defp ticket_sort_key(ticket, _sort_by),
    do: {ticket.priority || 0, ticket.number || 0, String.downcase(ticket.title || ""), ticket.id}

  defp sortable_datetime(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp sortable_datetime(_datetime), do: 0

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
