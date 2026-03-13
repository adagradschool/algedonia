defmodule AlgedoniaWeb.TicketLive.FilterHelpers do
  @moduledoc """
  URL query-parameter parsing and building for ticket list filtering.
  """
  use Phoenix.VerifiedRoutes, endpoint: AlgedoniaWeb.Endpoint, router: AlgedoniaWeb.Router

  @statuses Algedonia.Tickets.display_statuses()
  @valid_sort_fields [:priority, :inserted_at, :updated_at, :title]
  @valid_sort_orders [:asc, :desc]

  @doc """
  Extracts filter state from URL query params.
  """
  def filter_state_from_params(params) do
    %{
      view_mode: if(params["view"] == "list", do: :list, else: :board),
      filter_status: parse_status(params["status"]),
      filter_assignee: params["assignee"],
      filter_query: normalize_filter_query(params["q"])
    }
  end

  @doc """
  Returns true when any filter/sort/view value has changed.
  """
  def filters_changed?(assigns, fs) do
    !Map.has_key?(assigns, :filter_status) || assigns.filter_status != fs.filter_status ||
      assigns.filter_assignee != fs.filter_assignee ||
      Map.get(assigns, :filter_query) != fs.filter_query || assigns.view_mode != fs.view_mode
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

  @doc """
  Returns the default sort preferences for every ticket status.
  """
  def default_sort_preferences do
    Map.new(@statuses, fn status -> {status, default_sort_preference(status)} end)
  end

  @doc """
  Returns the default sort preference for a single status.
  """
  def default_sort_preference(_status), do: %{sort_by: :updated_at, sort_order: :desc}

  @doc """
  Normalizes a per-status sort preference payload into a full, safe preference map.
  """
  def normalize_sort_preferences(raw) when is_map(raw) do
    Enum.reduce(@statuses, default_sort_preferences(), fn status, acc ->
      case status_preference_value(raw, status) do
        preference when is_map(preference) ->
          Map.put(acc, status, normalize_sort_preference(status, preference))

        _ ->
          acc
      end
    end)
  end

  def normalize_sort_preferences(_raw), do: default_sort_preferences()

  @doc """
  Returns the sort preference for a single status, falling back to defaults.
  """
  def sort_preference(sort_preferences, status) when is_atom(status) do
    Map.get(sort_preferences || %{}, status, default_sort_preference(status))
  end

  @doc """
  Updates a single status sort preference and re-normalizes it.
  """
  def update_sort_preference(sort_preferences, status, attrs)
      when is_atom(status) and is_map(attrs) do
    current = sort_preference(sort_preferences, status)

    Map.put(sort_preferences || default_sort_preferences(), status, %{
      sort_by: parse_sort_field(pref_value(attrs, :sort_by), current.sort_by),
      sort_order: parse_sort_order(pref_value(attrs, :sort_order), current.sort_order)
    })
  end

  @doc """
  Encodes sort preferences into a JSON-safe payload for the client hook.
  """
  def encode_sort_preferences(sort_preferences) do
    Map.new(@statuses, fn status ->
      preference = sort_preference(sort_preferences, status)

      {to_string(status),
       %{
         sort_by: to_string(preference.sort_by),
         sort_order: to_string(preference.sort_order)
       }}
    end)
  end

  # -- Private --

  defp build_query_params(assigns, overrides) do
    view = Keyword.get(overrides, :view) || view_string(assigns.view_mode)
    status = Keyword.get(overrides, :status, assigns.filter_status)
    query = normalize_filter_query(Keyword.get(overrides, :q, assigns.filter_query))

    %{}
    |> then(&if(view != "board", do: Map.put(&1, :view, view), else: &1))
    |> then(&if(status in [nil, ""], do: &1, else: Map.put(&1, :status, status)))
    |> then(&if(query, do: Map.put(&1, :q, query), else: &1))
  end

  defp view_string(:list), do: "list"
  defp view_string(_), do: "board"

  @doc """
  Returns the stream name atom for a ticket status.
  """
  def stream_name(status), do: :"tickets_#{status}"

  @doc """
  Returns the stream entries for a status from the streams map.
  """
  def stream_for(streams, status), do: Map.get(streams, stream_name(status), [])

  defp normalize_filter_query(nil), do: nil

  defp normalize_filter_query(q) when is_binary(q),
    do: if(String.trim(q) == "", do: nil, else: String.trim(q))

  defp normalize_sort_preference(status, preference) do
    default = default_sort_preference(status)

    %{
      sort_by: parse_sort_field(pref_value(preference, :sort_by), default.sort_by),
      sort_order: parse_sort_order(pref_value(preference, :sort_order), default.sort_order)
    }
  end

  defp status_preference_value(preferences, status) do
    Map.get(preferences, status) || Map.get(preferences, to_string(status))
  end

  defp pref_value(values, key) do
    Map.get(values, key) || Map.get(values, to_string(key))
  end

  defp parse_sort_field(nil, default), do: default

  defp parse_sort_field(field, default) when is_atom(field) do
    if field in @valid_sort_fields, do: field, else: default
  end

  defp parse_sort_field(field, default) when is_binary(field) do
    atom = String.to_existing_atom(field)
    if atom in @valid_sort_fields, do: atom, else: default
  rescue
    ArgumentError -> default
  end

  defp parse_sort_field(_field, default), do: default

  defp parse_sort_order(nil, default), do: default

  defp parse_sort_order(order, default) when is_atom(order) do
    if order in @valid_sort_orders, do: order, else: default
  end

  defp parse_sort_order(order, default) when is_binary(order) do
    atom = String.to_existing_atom(order)
    if atom in @valid_sort_orders, do: atom, else: default
  rescue
    ArgumentError -> default
  end

  defp parse_sort_order(_order, default), do: default
end
