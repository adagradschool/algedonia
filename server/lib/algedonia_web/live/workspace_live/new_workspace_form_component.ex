defmodule AlgedoniaWeb.WorkspaceLive.NewWorkspaceFormComponent do
  @moduledoc """
  Live component that renders the new workspace creation form inside a modal.
  """
  use AlgedoniaWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form
        for={@form}
        phx-change="validate_new_workspace"
        phx-submit="create_new_workspace"
        class="space-y-4"
      >
        <.input field={@form[:name]} label="Workspace name" placeholder="My Project" required />

        <div class="flex justify-end gap-2 pt-2">
          <button
            type="button"
            phx-click="close_new_workspace_modal"
            class="px-4 py-2 text-sm text-fg-muted hover:text-fg transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="px-4 py-2 bg-accent-indigo hover:bg-accent-indigo-hover text-white font-medium rounded-lg transition-colors text-sm"
          >
            Create workspace
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
