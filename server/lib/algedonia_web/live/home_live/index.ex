defmodule AlgedoniaWeb.HomeLive.Index do
  @moduledoc """
  Workspace home page.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:nav_section, :inbox)}
  end
end
