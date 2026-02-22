defmodule AlgedoniaWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use AlgedoniaWeb, :html

  embed_templates "page_html/*"

  defp workspace_path(nil, path), do: path
  defp workspace_path(%{slug: slug}, path), do: "/w/#{slug}#{path}"
end
