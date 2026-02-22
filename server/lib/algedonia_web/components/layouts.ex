defmodule AlgedoniaWeb.Layouts do
  @moduledoc """
  Layout components — sidebar navigation and flash messaging.
  """
  use AlgedoniaWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the app layout with sidebar navigation.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_workspace, :map, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-surface">
      <aside class="w-64 flex-shrink-0 bg-surface-sidebar border-r border-border flex flex-col">
        <div class="px-4 pt-4 pb-3 flex items-center justify-between">
          <div class="flex items-center gap-2">
            <div class="w-7 h-7 bg-accent-indigo rounded-lg flex items-center justify-center">
              <.icon name="hero-square-3-stack-3d" class="size-4 text-white" />
            </div>
            <div class="flex flex-col">
              <span class="text-xs text-fg-muted">workspace</span>
              <span class="text-sm font-semibold text-fg">
                {if @current_workspace, do: @current_workspace.name, else: "Algedonia"}
              </span>
            </div>
          </div>
          <button class="size-7 rounded-md text-fg-muted hover:text-fg hover:bg-surface-raised transition-colors">
            <.icon name="hero-chevron-down-mini" class="size-4" />
          </button>
        </div>

        <div class="px-4 pb-3">
          <.link
            patch={workspace_path(@current_workspace, "/tickets/new")}
            class="flex items-center justify-center gap-2 w-full bg-surface-raised border border-border rounded-md text-xs font-medium text-fg hover:bg-surface-panel transition-colors py-1.5"
          >
            <.icon name="hero-plus-mini" class="size-4" /> New issue
          </.link>
        </div>

        <div class="px-4 pb-3">
          <div class="flex items-center gap-2 px-2 py-1.5 rounded-md bg-surface-panel border border-border-soft">
            <.icon name="hero-magnifying-glass-mini" class="size-4 text-fg-muted" />
            <input
              type="text"
              placeholder="Search"
              class="w-full bg-transparent border-0 text-xs text-fg placeholder-fg-muted focus:outline-none"
            />
          </div>
        </div>

        <nav class="flex-1 px-2 pb-2 space-y-0.5">
          <div class="px-2 pt-2 pb-1 text-[10px] uppercase tracking-wider text-fg-muted">
            Workspace
          </div>
          <.sidebar_link
            href={workspace_path(@current_workspace, "/")}
            icon="hero-inbox"
            label="Inbox"
            active={nav_active?(assigns, :inbox, "/")}
          />
          <.sidebar_link
            href={workspace_path(@current_workspace, "/tickets")}
            icon="hero-ticket"
            label="Issues"
            active={nav_active?(assigns, :issues, "/tickets")}
          />
          <.sidebar_link
            href={workspace_path(@current_workspace, "/monitor")}
            icon="hero-signal"
            label="Monitor"
            active={nav_active?(assigns, :monitor, "/monitor")}
          />
          <.sidebar_link
            href={workspace_path(@current_workspace, "/loops/primary")}
            icon="hero-cpu-chip"
            label="Loops"
            active={nav_active?(assigns, :loops, "/loops")}
          />
        </nav>

        <div class="p-4 border-t border-border">
          <div class="flex items-center justify-between text-[10px] uppercase tracking-wider text-fg-muted">
            <span>v0.1.0</span>
            <button class="text-fg-muted hover:text-fg transition-colors">Help</button>
          </div>
        </div>
      </aside>

      <main class="flex-1 flex flex-col overflow-hidden bg-surface">
        <div class="flex-1 overflow-auto">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp sidebar_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-1.5 rounded-md text-sm transition-colors",
        if(@active,
          do: "text-fg bg-surface-raised",
          else: "text-fg-muted hover:text-fg hover:bg-surface-panel"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </a>
    """
  end

  defp nav_active?(assigns, section, path) do
    case Map.get(assigns, :nav_section) do
      ^section -> true
      _ -> active_path?(Map.get(assigns, :current_path), path)
    end
  end

  defp workspace_path(nil, path), do: path

  defp workspace_path(%{slug: slug}, path) do
    "/w/#{slug}#{path}"
  end

  defp active_path?(nil, _path), do: false
  defp active_path?("/", "/"), do: true
  defp active_path?(current_path, "/"), do: current_path == "/"

  defp active_path?(current_path, path) when is_binary(current_path) do
    String.starts_with?(current_path, path)
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
