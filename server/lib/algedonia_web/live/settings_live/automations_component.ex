defmodule AlgedoniaWeb.SettingsLive.AutomationsComponent do
  @moduledoc """
  Live component for managing workspace transition hooks (automations)
  in the settings page.
  """
  use AlgedoniaWeb, :live_component

  alias Algedonia.Workspaces
  alias Algedonia.Workspaces.TransitionHook

  @status_options [
    {"Backlog", :backlog},
    {"Planning", :planning},
    {"In Progress", :in_progress},
    {"Halted", :halted},
    {"Completed", :completed},
    {"Archived", :archived}
  ]

  @impl true
  def update(assigns, socket) do
    hooks = Workspaces.list_transition_hooks(assigns.workspace.id)

    {:ok,
     socket
     |> assign(:workspace, assigns.workspace)
     |> assign(:hooks, hooks)
     |> assign(:show_form, false)
     |> assign_hook_form()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-base font-semibold text-fg">Automations</h2>
        <button
          :if={!@show_form}
          phx-click="show_hook_form"
          phx-target={@myself}
          type="button"
          class="px-3 py-1.5 text-xs font-medium text-accent-indigo border border-accent-indigo/40 bg-accent-indigo/10 rounded-md hover:bg-accent-indigo/20 transition-colors"
        >
          Add automation
        </button>
      </div>

      <p :if={@hooks == [] && !@show_form} class="text-sm text-fg-muted">
        No automations configured. Add one to run an agent when tickets change status.
      </p>

      <div :if={@show_form} class="mb-4 p-4 bg-surface-panel border border-border rounded-lg">
        <.form for={@hook_form} phx-submit="save_hook" phx-target={@myself} class="space-y-3">
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block text-xs font-medium text-fg-muted mb-1">From status</label>
              <select
                name="hook[from_status]"
                class="w-full px-3 py-2 bg-surface border border-border rounded-lg text-fg text-sm focus:outline-none focus:ring-2 focus:ring-accent-indigo focus:border-transparent"
              >
                <option :for={{label, value} <- status_options()} value={value}>{label}</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-fg-muted mb-1">To status</label>
              <select
                name="hook[to_status]"
                class="w-full px-3 py-2 bg-surface border border-border rounded-lg text-fg text-sm focus:outline-none focus:ring-2 focus:ring-accent-indigo focus:border-transparent"
              >
                <option :for={{label, value} <- status_options()} value={value}>{label}</option>
              </select>
            </div>
          </div>
          <div>
            <label class="block text-xs font-medium text-fg-muted mb-1">Instruction</label>
            <textarea
              name="hook[instruction]"
              rows="3"
              required
              placeholder="Describe what the agent should do when this transition occurs..."
              class="w-full px-3 py-2 bg-surface border border-border rounded-lg text-fg text-sm placeholder-fg-muted focus:outline-none focus:ring-2 focus:ring-accent-indigo focus:border-transparent resize-y"
            />
          </div>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="cancel_hook_form"
              phx-target={@myself}
              class="px-3 py-1.5 text-xs font-medium text-fg-muted hover:text-fg transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-4 py-1.5 bg-accent-indigo hover:bg-accent-indigo-hover text-white font-medium rounded-lg transition-colors text-xs"
            >
              Save
            </button>
          </div>
        </.form>
      </div>

      <div :if={@hooks != []} class="space-y-2">
        <div
          :for={hook <- @hooks}
          class="flex items-center justify-between px-3 py-2 rounded-md bg-surface-panel"
        >
          <div class="flex-1 min-w-0">
            <span class="text-xs font-medium text-fg">
              {format_status(hook.from_status)} → {format_status(hook.to_status)}
            </span>
            <p class="text-xs text-fg-muted truncate mt-0.5">{hook.instruction}</p>
          </div>
          <button
            type="button"
            phx-click="delete_hook"
            phx-value-id={hook.id}
            phx-target={@myself}
            class="ml-3 text-xs text-fg-muted hover:text-red-400 transition-colors flex-shrink-0"
          >
            Delete
          </button>
        </div>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("show_hook_form", _params, socket) do
    {:noreply, assign(socket, :show_form, true)}
  end

  def handle_event("cancel_hook_form", _params, socket) do
    {:noreply, assign(socket, show_form: false) |> assign_hook_form()}
  end

  def handle_event("save_hook", %{"hook" => params}, socket) do
    workspace = socket.assigns.workspace

    case Workspaces.create_transition_hook(workspace, params) do
      {:ok, _hook} ->
        hooks = Workspaces.list_transition_hooks(workspace.id)

        {:noreply,
         socket
         |> assign(hooks: hooks, show_form: false)
         |> assign_hook_form()
         |> put_flash(:info, "Automation added.")}

      {:error, %Ecto.Changeset{} = cs} ->
        msg = changeset_error_message(cs)
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("delete_hook", %{"id" => id}, socket) do
    hook = Workspaces.get_transition_hook(id)

    if hook do
      {:ok, _} = Workspaces.delete_transition_hook(hook)
      hooks = Workspaces.list_transition_hooks(socket.assigns.workspace.id)

      {:noreply,
       socket
       |> assign(:hooks, hooks)
       |> put_flash(:info, "Automation removed.")}
    else
      {:noreply, socket}
    end
  end

  defp assign_hook_form(socket) do
    changeset = TransitionHook.changeset(%TransitionHook{}, %{})
    assign(socket, :hook_form, to_form(changeset, as: "hook"))
  end

  defp status_options, do: @status_options

  defp format_status(:in_progress), do: "In Progress"
  defp format_status(status), do: status |> Atom.to_string() |> String.capitalize()

  defp changeset_error_message(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {_field, errors} -> Enum.join(errors, ", ") end)
    |> case do
      "" -> "Could not save automation."
      msg -> msg
    end
  end
end
