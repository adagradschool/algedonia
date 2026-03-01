defmodule AlgedoniaWeb.TicketLive.FilterHelpers do
  @moduledoc """
  URL query-parameter parsing and building for ticket list filtering.
  """
  use Phoenix.VerifiedRoutes, endpoint: AlgedoniaWeb.Endpoint, router: AlgedoniaWeb.Router

  @statuses Algedonia.Tickets.display_statuses()

  @doc """
  Extracts filter state from URL query params.
  """
  def filter_state_from_params(params) do
    %{
      view_mode: if(params["view"] == "list", do: :list, else: :board),
      filter_status: parse_status(params["status"]),
      filter_assignee: params["assignee"],
      filter_query: normalize_filter_query(params["q"]),
      sort_by: parse_sort_by(params["sort_by"]),
      sort_order: parse_sort_order(params["sort_order"])
    }
  end

  @doc """
  Returns true when any filter/sort/view value has changed.
  """
  def filters_changed?(assigns, fs) do
    !Map.has_key?(assigns, :filter_status) || assigns.filter_status != fs.filter_status ||
      assigns.filter_assignee != fs.filter_assignee ||
      Map.get(assigns, :filter_query) != fs.filter_query ||
      assigns.view_mode != fs.view_mode || Map.get(assigns, :sort_by) != fs.sort_by ||
      Map.get(assigns, :sort_order) != fs.sort_order
  end

  @doc """
  Builds the tickets path with merged query-param overrides.
  """
  def tickets_path(socket_or_assigns, overrides \\ [])

  def tickets_path(%{assigns: assigns}, overrides),
    do: tickets_path(assigns, overrides)

  def tickets_path(assigns, overrides) do
    ~p"/w/#{assigns.workspace_slug}/tickets?#{build_query_params(assigns, overrides)}"
  end

  def parse_status(nil), do: nil
  def parse_status(""), do: nil

  def parse_status(s) when is_binary(s),
    do: if(s in Enum.map(@statuses, &to_string/1), do: String.to_existing_atom(s))

  def parse_status(s) when is_atom(s), do: s

  # -- Private --

  defp parse_sort_by(nil), do: :priority
  defp parse_sort_by("inserted_at"), do: :inserted_at
  defp parse_sort_by("title"), do: :title
  defp parse_sort_by(_), do: :priority

  defp parse_sort_order(nil), do: :asc
  defp parse_sort_order("desc"), do: :desc
  defp parse_sort_order(_), do: :asc

  defp build_query_params(assigns, overrides) do
    view = Keyword.get(overrides, :view) || view_string(assigns.view_mode)
    status = Keyword.get(overrides, :status, assigns.filter_status)
    sort_by = Keyword.get(overrides, :sort_by, assigns.sort_by)
    query = normalize_filter_query(Keyword.get(overrides, :q, assigns.filter_query))

    %{}
    |> then(&if(view != "board", do: Map.put(&1, :view, view), else: &1))
    |> then(&if(status in [nil, ""], do: &1, else: Map.put(&1, :status, status)))
    |> then(
      &if(sort_by && to_string(sort_by) != "priority",
        do: Map.put(&1, :sort_by, sort_by),
        else: &1
      )
    )
    |> then(&if(query, do: Map.put(&1, :q, query), else: &1))
  end

  defp view_string(:list), do: "list"
  defp view_string(_), do: "board"

  defp normalize_filter_query(nil), do: nil

  defp normalize_filter_query(q) when is_binary(q),
    do: if(String.trim(q) == "", do: nil, else: String.trim(q))
end
