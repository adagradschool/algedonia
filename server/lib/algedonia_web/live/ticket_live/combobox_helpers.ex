defmodule AlgedoniaWeb.TicketLive.ComboboxHelpers do
  @moduledoc false

  alias Phoenix.HTML.Form

  def options_visible?(open, search), do: open and query_present?(search)

  def query_present?(search) do
    search
    |> to_string()
    |> String.trim()
    |> Kernel.!=("")
  end

  def blocker_selection_changed?(_form, %{} = params) when not is_map_key(params, "blocked_by"),
    do: false

  def blocker_selection_changed?(form, %{} = params) do
    current_blocked_by_selection(form) != normalize_multi_value(Map.get(params, "blocked_by"))
  end

  def current_blocked_by_selection(%Form{source: source}),
    do: current_blocked_by_selection(source)

  def current_blocked_by_selection(%Ecto.Changeset{} = changeset) do
    case changeset.params do
      %{"blocked_by" => blocked_by} -> normalize_multi_value(blocked_by)
      _ -> normalize_multi_value(Ecto.Changeset.get_field(changeset, :blocked_by, []))
    end
  end

  def normalize_multi_value(nil), do: []
  def normalize_multi_value(""), do: []

  def normalize_multi_value(values) when is_list(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def normalize_multi_value(value), do: [to_string(value)]
end
