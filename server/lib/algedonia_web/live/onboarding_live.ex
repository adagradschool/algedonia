defmodule AlgedoniaWeb.OnboardingLive do
  use AlgedoniaWeb, :live_view

  alias Algedonia.Workspaces

  import AlgedoniaWeb.Helpers, only: [slugify: 1]

  @impl true
  def mount(_params, _session, socket) do
    changeset = Ecto.Changeset.change(%Algedonia.Workspaces.Workspace{})
    {:ok, assign(socket, form: to_form(changeset), error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center px-4">
      <div class="max-w-md w-full space-y-8">
        <div class="text-center">
          <div class="flex items-center justify-center gap-3 mb-4">
            <div class="w-10 h-10 bg-accent-indigo rounded-xl flex items-center justify-center">
              <.icon name="hero-square-3-stack-3d" class="size-6 text-white" />
            </div>
            <h1 class="text-2xl font-bold text-fg">Welcome to Algedonia</h1>
          </div>
          <p class="text-fg-secondary">Create your first workspace to get started.</p>
        </div>

        <.form for={@form} phx-submit="create_workspace" class="space-y-4">
          <div>
            <label for="workspace_name" class="block text-sm font-medium text-fg mb-1">
              Workspace name
            </label>
            <input
              type="text"
              name="workspace[name]"
              id="workspace_name"
              value={@form[:name].value}
              placeholder="My Project"
              required
              class="w-full px-3 py-2 bg-surface-panel border border-border rounded-lg text-fg text-sm placeholder-fg-muted focus:outline-none focus:ring-2 focus:ring-accent-indigo focus:border-transparent"
            />
          </div>

          <p :if={@error} class="text-sm text-red-400">{@error}</p>

          <button
            type="submit"
            class="w-full px-4 py-2.5 bg-accent-indigo hover:bg-accent-indigo-hover text-white font-medium rounded-lg transition-colors text-sm"
          >
            Create workspace
          </button>
        </.form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("create_workspace", %{"workspace" => %{"name" => name}}, socket) do
    user = socket.assigns.current_user
    slug = slugify(name)
    prefix = Workspaces.prefix_for_name(name)

    case Workspaces.create_workspace(%{name: name, slug: slug, prefix: prefix}) do
      {:ok, workspace} ->
        Workspaces.ensure_membership(workspace, user)

        {:noreply,
         socket
         |> push_navigate(to: ~p"/w/#{workspace.slug}/tickets")}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: "Could not create workspace. Try a different name.")}
    end
  end
end
