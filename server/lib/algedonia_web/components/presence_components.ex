defmodule AlgedoniaWeb.PresenceComponents do
  @moduledoc """
  Components for displaying user presence indicators.
  """
  use Phoenix.Component

  import AlgedoniaWeb.CommentComponents, only: [avatar: 1]

  @max_visible 5

  attr :presences, :list, required: true
  attr :current_user, :string, required: true

  def presence_indicator(assigns) do
    others =
      assigns.presences
      |> Enum.reject(&(&1.display_name == assigns.current_user))
      |> Enum.uniq_by(& &1.display_name)

    visible = Enum.take(others, @max_visible)
    overflow = length(others) - length(visible)

    assigns =
      assigns
      |> assign(:others, others)
      |> assign(:visible, visible)
      |> assign(:overflow, overflow)

    ~H"""
    <div :if={@others != []} class="flex items-center gap-1.5">
      <span class="text-xs text-fg-muted">also viewing</span>
      <div class="flex -space-x-1">
        <div :for={user <- @visible} title={user.display_name}>
          <.avatar name={user.display_name} size="sm" />
        </div>
      </div>
      <span :if={@overflow > 0} class="text-xs text-fg-muted">
        +{@overflow} more
      </span>
    </div>
    """
  end
end
