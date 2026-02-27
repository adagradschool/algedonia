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

  attr :current_workspace, :map, required: true
  attr :current_user, :map, default: nil

  attr :nav_section, :atom,
    default: nil,
    doc: "active navigation section (:inbox, :issues, :monitor)"

  attr :current_path, :string, default: nil, doc: "current request path for nav fallback"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="h-screen overflow-hidden bg-surface">
      <div
        id="global-command-palette"
        phx-hook="CommandPalette"
        data-tickets-path={workspace_path(@current_workspace, "/tickets")}
        data-monitor-path={workspace_path(@current_workspace, "/monitor")}
        data-new-issue-path={workspace_path(@current_workspace, "/tickets/new")}
      />
      <div
        id="workspace-layout"
        phx-hook="SidebarPanel"
        data-min-width="224"
        data-max-width="448"
        data-default-width="256"
        data-collapsed-width="52"
        data-handle-width="16"
        data-storage-key="workspace-left-sidebar-width"
        class="h-full grid grid-cols-[var(--left-sidebar-width,16rem)_16px_minmax(0,1fr)] overflow-hidden"
      >
        <div id="workspace-left-sidebar-panel" data-sidebar-panel class="min-w-0 overflow-hidden">
          <.workspace_sidebar
            current_workspace={@current_workspace}
            current_user={@current_user}
            inbox_active={nav_active?(assigns, :inbox, "/")}
            issues_active={nav_active?(assigns, :issues, "/tickets")}
            monitor_active={nav_active?(assigns, :monitor, "/monitor")}
            class="!w-full h-full border-r-0"
          />
        </div>

        <div class="group relative bg-surface">
          <button
            type="button"
            data-sidebar-handle
            aria-label="Resize sidebar"
            aria-controls="workspace-left-sidebar-panel"
            class="h-full w-full cursor-col-resize touch-none focus:outline-none border-0 bg-transparent p-0 appearance-none"
          >
            <span class="pointer-events-none mx-auto block h-full w-px bg-border transition-colors group-hover:bg-accent-indigo/70 group-focus-within:bg-accent-indigo/70" />
          </button>
          <button
            type="button"
            data-sidebar-toggle
            aria-controls="workspace-left-sidebar-panel"
            aria-label="Collapse sidebar"
            title="Collapse sidebar"
            class="group absolute left-1/2 top-2 -translate-x-1/2 inline-flex h-4 w-4 items-center justify-center rounded border border-border bg-surface-panel text-fg-muted hover:text-fg hover:bg-surface-raised transition-colors"
          >
            <.icon
              name="hero-chevron-left-mini"
              class="size-3 transition-transform group-data-[state=collapsed]:rotate-180"
            />
          </button>
        </div>

        <main class="flex-1 flex flex-col overflow-hidden bg-surface">
          <div class="flex-1 overflow-auto">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :current_workspace, :map, required: true
  attr :current_user, :map, default: nil
  attr :inbox_active, :boolean, default: false
  attr :issues_active, :boolean, default: false
  attr :monitor_active, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block

  def workspace_sidebar(assigns) do
    ~H"""
    <aside
      data-sidebar-shell
      class={[
        "workspace-sidebar",
        "w-64 flex-shrink-0 bg-surface-sidebar border-r border-border flex flex-col overflow-hidden",
        @class
      ]}
    >
      <div class="px-4 pt-4 pb-3 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <div class="w-7 h-7 bg-accent-indigo rounded-lg flex items-center justify-center">
            <.icon name="hero-square-3-stack-3d" class="size-4 text-white" />
          </div>
          <div data-sidebar-expanded-only class="flex flex-col">
            <span class="text-xs text-fg-muted">workspace</span>
            <span class="text-sm font-semibold text-fg">
              {@current_workspace.name}
            </span>
          </div>
        </div>
      </div>

      <div class="workspace-sidebar-create px-4 pb-3">
        <.link
          patch={workspace_path(@current_workspace, "/tickets/new")}
          title="New issue"
          class="workspace-sidebar-new-issue flex items-center justify-center gap-2 w-full bg-surface-raised border border-border rounded-md text-xs font-medium text-fg hover:bg-surface-panel transition-colors min-h-11 px-3"
        >
          <.icon name="hero-plus-mini" class="size-4" />
          <span data-sidebar-expanded-only>New issue</span>
        </.link>
      </div>

      <nav class="px-2 pb-2 space-y-0.5 border-b border-border-soft">
        <div
          data-sidebar-expanded-only
          class="px-2 pt-2 pb-1 text-[10px] uppercase tracking-wider text-fg-muted"
        >
          Workspace
        </div>
        <.sidebar_link
          href={workspace_path(@current_workspace, "/")}
          icon="hero-inbox"
          label="Inbox"
          active={@inbox_active}
        />
        <.sidebar_link
          href={workspace_path(@current_workspace, "/tickets")}
          icon="hero-ticket"
          label="Issues"
          active={@issues_active}
        />
        <.sidebar_link
          href={workspace_path(@current_workspace, "/monitor")}
          icon="hero-signal"
          label="Monitor"
          active={@monitor_active}
        />
      </nav>

      <div
        :if={@inner_block != []}
        data-sidebar-slot
        class="flex-1 min-h-0 p-3 overflow-y-auto"
      >
        {render_slot(@inner_block)}
      </div>
      <div :if={@inner_block == []} class="flex-1"></div>

      <div class="p-3 border-t border-border">
        <div :if={@current_user} class="group relative">
          <button
            title={@current_user.name || @current_user.github_username}
            class="workspace-sidebar-account flex items-center gap-2 w-full px-2 py-1.5 rounded-md hover:bg-surface-panel transition-colors"
          >
            <img
              :if={@current_user.avatar_url}
              src={@current_user.avatar_url}
              class="size-6 rounded-full"
              alt=""
            />
            <div
              :if={!@current_user.avatar_url}
              class="size-6 rounded-full bg-accent-indigo flex items-center justify-center text-white text-xs font-medium"
            >
              {String.first(@current_user.name || "?")}
            </div>
            <span
              data-sidebar-expanded-only
              class="text-sm text-fg flex-1 text-left whitespace-normal break-words leading-snug"
            >
              {@current_user.name || @current_user.github_username}
            </span>
            <span data-sidebar-expanded-only>
              <.icon name="hero-chevron-up-down-mini" class="size-4 text-fg-muted" />
            </span>
          </button>
          <div class="absolute bottom-full left-0 right-0 mb-1 bg-surface-panel border border-border rounded-lg shadow-lg opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all z-50">
            <.link
              href={~p"/auth/logout"}
              method="delete"
              class="flex items-center gap-2 px-3 py-2 text-sm text-fg-muted hover:text-fg hover:bg-surface-raised rounded-lg transition-colors"
            >
              <.icon name="hero-arrow-right-start-on-rectangle-mini" class="size-4" /> Sign out
            </.link>
          </div>
        </div>
      </div>
    </aside>
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
      title={@label}
      class={[
        "workspace-sidebar-link group relative flex items-center gap-3 px-3 py-1.5 rounded-md text-sm transition-all duration-150",
        if(@active,
          do: "text-fg bg-surface-raised font-medium",
          else: "text-fg-muted hover:text-fg hover:bg-surface-panel"
        )
      ]}
    >
      <span
        :if={@active}
        data-sidebar-expanded-only
        class="absolute left-0 top-1/2 -translate-y-1/2 w-[3px] h-4 rounded-r-full bg-accent-indigo motion-safe:animate-[indicator-in_200ms_ease-out]"
      />
      <.icon name={@icon} class="workspace-sidebar-link-icon size-4" />
      <span data-sidebar-expanded-only>{@label}</span>
    </a>
    """
  end

  defp nav_active?(assigns, section, path) do
    case Map.get(assigns, :nav_section) do
      ^section -> true
      _ -> active_path?(Map.get(assigns, :current_path), path)
    end
  end

  defp workspace_path(%{slug: slug}, path), do: "/w/#{slug}#{path}"

  @doc false
  def active_path?(nil, _path), do: false

  def active_path?(current_path, "/") when is_binary(current_path) do
    # Home matches exact root or workspace root (/w/slug or /w/slug/)
    current_path == "/" or Regex.match?(~r"^/w/[^/]+/?$", current_path)
  end

  def active_path?(current_path, path) when is_binary(current_path) do
    # Match bare path or workspace-scoped path (/w/slug/path)
    String.starts_with?(current_path, path) or
      Regex.match?(~r"^/w/[^/]+#{Regex.escape(path)}", current_path)
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
