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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden">
      <aside class="w-56 flex-shrink-0 bg-surface-sidebar border-r border-border flex flex-col">
        <div class="p-4 flex items-center gap-2">
          <div class="w-6 h-6 bg-accent-indigo rounded flex items-center justify-center">
            <.icon name="hero-square-3-stack-3d" class="size-3.5 text-white" />
          </div>
          <span class="text-sm font-bold text-fg">Algedonia</span>
        </div>

        <nav class="flex-1 px-2 py-2 space-y-0.5">
          <.sidebar_link href="/" icon="hero-home" label="Home" />
          <.sidebar_link href="/tickets" icon="hero-ticket" label="Tickets" active />
        </nav>

        <div class="p-4 border-t border-border">
          <span class="text-[10px] uppercase tracking-wider font-bold text-fg-muted">
            v0.1.0
          </span>
        </div>
      </aside>

      <main class="flex-1 flex flex-col overflow-hidden">
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
        "flex items-center gap-3 px-3 py-1.5 rounded text-sm transition-colors",
        if(@active,
          do: "text-fg bg-surface-raised",
          else: "text-fg-muted hover:text-fg"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </a>
    """
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
