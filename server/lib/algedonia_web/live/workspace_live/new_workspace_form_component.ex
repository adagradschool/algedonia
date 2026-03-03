defmodule AlgedoniaWeb.WorkspaceLive.NewWorkspaceFormComponent do
  @moduledoc """
  Live component that renders the new workspace creation form inside a modal.
  Includes a GitHub repo picker when a token is available.
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
        <%!-- Repository picker --%>
        <div>
          <label class="block text-sm font-medium text-fg mb-1">GitHub repository</label>

          <div :if={!@show_url_input && @repos != []}>
            <%!-- Selected state --%>
            <button
              :if={@github_repo_url && !@repo_dropdown_open}
              type="button"
              phx-click="new_ws_open_repo_dropdown"
              class="w-full flex items-center justify-between px-3 py-2 bg-surface-panel border border-accent-indigo/50 rounded-lg text-sm text-fg hover:border-accent-indigo transition-colors"
            >
              <div class="flex items-center gap-2 min-w-0">
                <.icon name="hero-check-circle-solid" class="size-4 text-accent-indigo shrink-0" />
                <span class="text-accent-indigo font-medium truncate">
                  {selected_repo_name(@repos, @github_repo_url)}
                </span>
              </div>
              <.icon name="hero-chevron-down-mini" class="size-4 text-fg-muted shrink-0" />
            </button>

            <%!-- Closed state: prompt to select --%>
            <button
              :if={!@github_repo_url && !@repo_dropdown_open}
              type="button"
              phx-click="new_ws_open_repo_dropdown"
              class="w-full flex items-center justify-between px-3 py-2 bg-surface-panel border border-border rounded-lg text-sm text-fg-muted hover:border-fg-muted transition-colors"
            >
              <span>Select a repository...</span>
              <.icon name="hero-chevron-down-mini" class="size-4 text-fg-muted shrink-0" />
            </button>

            <%!-- Open dropdown --%>
            <div :if={@repo_dropdown_open} class="relative">
              <input
                type="text"
                phx-change="new_ws_search_repos"
                phx-debounce="150"
                name="repo_search"
                value={@repo_search}
                placeholder="Search your repositories..."
                autofocus
                class="w-full px-3 py-2 bg-surface-panel border border-accent-indigo rounded-lg text-fg text-sm placeholder-fg-muted focus:outline-none focus:ring-2 focus:ring-accent-indigo focus:border-transparent"
              />
              <div class="mt-1 max-h-48 overflow-y-auto bg-surface-panel border border-border rounded-lg">
                <button
                  :for={repo <- filtered_repos(@repos, @repo_search)}
                  type="button"
                  phx-click="new_ws_select_repo"
                  phx-value-url={repo.html_url}
                  phx-value-name={repo.name}
                  class={[
                    "w-full text-left px-3 py-2.5 transition-colors border-l-2",
                    @github_repo_url == repo.html_url &&
                      "border-l-accent-indigo bg-accent-indigo/15",
                    @github_repo_url != repo.html_url &&
                      "border-l-transparent hover:bg-surface-raised"
                  ]}
                >
                  <div class="flex items-center gap-2">
                    <.icon
                      :if={@github_repo_url == repo.html_url}
                      name="hero-check-circle-solid"
                      class="size-4 text-accent-indigo shrink-0"
                    />
                    <span class={[
                      "text-sm font-medium truncate",
                      @github_repo_url == repo.html_url && "text-accent-indigo",
                      @github_repo_url != repo.html_url && "text-fg"
                    ]}>
                      {repo.full_name}
                    </span>
                    <span
                      :if={repo.private}
                      class="text-[10px] text-fg-muted bg-surface-raised px-1.5 py-0.5 rounded"
                    >
                      private
                    </span>
                  </div>
                  <p :if={repo.description} class="text-xs text-fg-muted truncate mt-0.5">
                    {repo.description}
                  </p>
                </button>
              </div>
            </div>

            <button
              type="button"
              phx-click="new_ws_toggle_url_input"
              class="mt-2 text-xs text-accent-indigo hover:underline"
            >
              Or paste a URL
            </button>
          </div>

          <div :if={@show_url_input || @repos == []}>
            <input
              type="url"
              name="workspace[github_repo_url]"
              placeholder="https://github.com/user/repo"
              value={@github_repo_url || ""}
              class="w-full px-3 py-2 bg-surface-panel border border-border rounded-lg text-fg text-sm placeholder-fg-muted focus:outline-none focus:ring-2 focus:ring-accent-indigo focus:border-transparent"
            />
            <button
              :if={@repos != []}
              type="button"
              phx-click="new_ws_toggle_url_input"
              class="mt-2 text-xs text-accent-indigo hover:underline"
            >
              Pick from your repos
            </button>
          </div>

          <input
            :if={!@show_url_input && @github_repo_url}
            type="hidden"
            name="workspace[github_repo_url]"
            value={@github_repo_url}
          />
        </div>

        <%!-- Workspace name --%>
        <div>
          <label for="new_ws_name" class="block text-sm font-medium text-fg mb-1">
            Workspace name
          </label>
          <input
            type="text"
            name="workspace[name]"
            id="new_ws_name"
            value={@workspace_name || @form[:name].value}
            placeholder="My Project"
            required
            class="w-full px-3 py-2 bg-surface-panel border border-border rounded-lg text-fg text-sm placeholder-fg-muted focus:outline-none focus:ring-2 focus:ring-accent-indigo focus:border-transparent"
          />
        </div>

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

  defp selected_repo_name(repos, url) do
    case Enum.find(repos, &(&1.html_url == url)) do
      nil -> url
      repo -> repo.full_name
    end
  end

  defp filtered_repos(repos, ""), do: Enum.take(repos, 20)

  defp filtered_repos(repos, search) do
    q = String.downcase(search)

    repos
    |> Enum.filter(fn repo ->
      String.contains?(String.downcase(repo.full_name || ""), q) ||
        String.contains?(String.downcase(repo.description || ""), q)
    end)
    |> Enum.take(20)
  end
end
