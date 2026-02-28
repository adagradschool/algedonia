defmodule AlgedoniaWeb.Helpers do
  @moduledoc """
  Shared web-layer utilities for controllers and LiveViews.
  """

  @doc """
  Traverses changeset errors into a human-readable map.
  """
  @spec format_errors(Ecto.Changeset.t()) :: map()
  def format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
      |> sentence_case()
    end)
  end

  @doc """
  Puts `value` into `map` under `key` unless `value` is nil.
  """
  @spec maybe_put(map(), String.t(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Converts a human-readable name into a URL-friendly slug.

  Downcases, strips non-alphanumeric characters (except hyphens and spaces),
  collapses whitespace/hyphens into single hyphens, and trims leading/trailing
  hyphens. Returns `"workspace"` if the result would be empty.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "workspace"
      slug -> slug
    end
  end

  @spec sentence_case(String.t()) :: String.t()
  def sentence_case(""), do: ""

  def sentence_case(text) do
    case String.next_grapheme(text) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> text
    end
  end

  @doc """
  Returns a human-readable reference for a ticket — its number (as a string)
  when available, otherwise its UUID.
  """
  @spec ticket_ref(%{number: integer()} | %{id: String.t()}) :: String.t()
  def ticket_ref(%{number: number}) when is_integer(number), do: Integer.to_string(number)
  def ticket_ref(%{id: id}), do: id

  @doc """
  Truncates a UUID to its first 8 characters for display.

  Returns `nil` when given `nil` or a non-binary value.
  """
  @spec short_id(String.t() | nil) :: String.t() | nil
  def short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  def short_id(_), do: nil

  @doc """
  Resolves a daemon for the current loop, preferring the assigned daemon
  if it is online, falling back to any online daemon.
  """
  @spec resolve_daemon(Phoenix.LiveView.Socket.t()) ::
          {:ok, Algedonia.Daemons.Daemon.t()} | {:error, :no_online_daemon}
  def resolve_daemon(socket) do
    case socket.assigns[:loop_record] do
      %{assigned_daemon_id: daemon_id} when is_binary(daemon_id) ->
        case Algedonia.Daemons.get_daemon(daemon_id) do
          %{status: :online} = daemon -> {:ok, daemon}
          _ -> Algedonia.Daemons.find_online()
        end

      _ ->
        Algedonia.Daemons.find_online()
    end
  end

  @doc """
  Formats a `DateTime` as a human-readable relative time string.

  Returns `""` for `nil`.
  """
  @spec relative_time_text(DateTime.t() | nil) :: String.t()
  def relative_time_text(nil), do: ""

  def relative_time_text(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end
end
