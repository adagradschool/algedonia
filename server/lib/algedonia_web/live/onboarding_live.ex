defmodule AlgedoniaWeb.OnboardingLive do
  use AlgedoniaWeb, :live_view

  alias Algedonia.{Accounts.GitHub, Daemons, TenantScope, Tickets, Workspaces}

  import AlgedoniaWeb.Helpers, only: [slugify: 1]

  @impl true
  def mount(_params, _session, socket) do
    socket = determine_initial_step(socket)

    if connected?(socket) && socket.assigns[:workspace] do
      Daemons.subscribe(socket.assigns.workspace.id)
    end

    {:ok, socket}
  end

  # -- Resume logic --

  defp determine_initial_step(socket) do
    case socket.assigns.existing_workspace do
      nil ->
        init_workspace_step(socket)

      workspace ->
        ticket_count =
          TenantScope.with_workspace(workspace.id, fn ->
            Tickets.list_tickets(workspace_id: workspace.id) |> length()
          end)

        if ticket_count > 0 do
          push_navigate(socket, to: ~p"/w/#{workspace.slug}/tickets")
        else
          socket
          |> assign(:workspace, workspace)
          |> init_daemon_step()
        end
    end
  end

  defp init_workspace_step(socket) do
    changeset = Ecto.Changeset.change(%Workspaces.Workspace{})
    repos = fetch_repos(socket.assigns[:github_token])

    assign(socket,
      step: :workspace,
      workspace: nil,
      form: to_form(changeset),
      error: nil,
      repos: repos,
      repo_search: "",
      show_url_input: repos == [],
      repo_dropdown_open: false,
      github_repo_url: nil,
      workspace_name: nil,
      daemon_status: :waiting,
      os: nil,
      server_url: AlgedoniaWeb.Endpoint.url()
    )
  end

  defp init_daemon_step(socket) do
    daemon_status = check_daemon_status()

    assign(socket,
      step: :daemon,
      error: nil,
      daemon_status: daemon_status,
      os: nil,
      server_url: AlgedoniaWeb.Endpoint.url()
    )
  end

  defp fetch_repos(nil) do
    []
  end

  defp fetch_repos(token) do
    case GitHub.list_user_repos(token) do
      {:ok, repos} ->
        repos

      {:error, _reason} ->
        []
    end
  end

  defp check_daemon_status(workspace_slug \\ nil) do
    case Daemons.find_online() do
      {:ok, daemon} ->
        ready =
          if workspace_slug,
            do: Daemons.repo_ready?(daemon.name, workspace_slug),
            else: false

        if ready, do: :repo_ready, else: :connected

      {:error, _} ->
        :waiting
    end
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="min-h-screen flex flex-col items-center justify-center px-4"
      id="onboarding"
      phx-hook="OsDetect"
    >
      <div class="max-w-xl w-full space-y-8">
        <%!-- Step indicator --%>
        <div class="flex items-center justify-center gap-2">
          <.step_dot step={:workspace} current={@step} />
          <div class="w-8 h-px bg-border" />
          <.step_dot step={:daemon} current={@step} />
        </div>

        <%!-- Step 1: Workspace --%>
        <div :if={@step == :workspace}>
          <div class="text-center mb-6">
            <div class="flex items-center justify-center gap-3 mb-4">
              <div class="w-10 h-10 bg-accent-indigo rounded-xl flex items-center justify-center">
                <.icon name="hero-square-3-stack-3d" class="size-6 text-white" />
              </div>
              <h1 class="text-2xl font-bold text-fg">Create your workspace</h1>
            </div>
            <p class="text-fg-secondary text-sm">Connect a GitHub repo to start building.</p>
          </div>

          <.form for={@form} phx-submit="create_workspace" class="space-y-4">
            <%!-- Repository (first) --%>
            <div>
              <label class="block text-sm font-medium text-fg mb-1">
                GitHub repository
              </label>

              <div :if={!@show_url_input && @repos != []}>
                <%!-- Selected state: show selection, click to reopen --%>
                <button
                  :if={@github_repo_url && !@repo_dropdown_open}
                  type="button"
                  phx-click="open_repo_dropdown"
                  class="w-full flex items-center justify-between px-3 py-2 bg-surface-panel border border-accent-indigo/50 rounded-lg text-sm text-fg hover:border-accent-indigo transition-colors"
                >
                  <div class="flex items-center gap-2 min-w-0">
                    <.icon
                      name="hero-check-circle-solid"
                      class="size-4 text-accent-indigo shrink-0"
                    />
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
                  phx-click="open_repo_dropdown"
                  class="w-full flex items-center justify-between px-3 py-2 bg-surface-panel border border-border rounded-lg text-sm text-fg-muted hover:border-fg-muted transition-colors"
                >
                  <span>Select a repository...</span>
                  <.icon name="hero-chevron-down-mini" class="size-4 text-fg-muted shrink-0" />
                </button>

                <%!-- Open dropdown --%>
                <div :if={@repo_dropdown_open} class="relative">
                  <input
                    type="text"
                    phx-change="search_repos"
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
                      phx-click="select_repo"
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
                  phx-click="toggle_url_input"
                  class="mt-2 text-xs text-accent-indigo hover:underline"
                >
                  Or paste a URL for private repos
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
                  phx-click="toggle_url_input"
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

            <%!-- Workspace name (second, auto-filled from repo) --%>
            <div>
              <label for="workspace_name" class="block text-sm font-medium text-fg mb-1">
                Workspace name
              </label>
              <input
                type="text"
                name="workspace[name]"
                id="workspace_name"
                value={@workspace_name || @form[:name].value}
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

        <%!-- Step 2: Daemon --%>
        <div :if={@step == :daemon}>
          <div class="text-center mb-6">
            <div class="flex items-center justify-center gap-3 mb-4">
              <div class="w-10 h-10 bg-accent-indigo rounded-xl flex items-center justify-center">
                <.icon name="hero-signal" class="size-6 text-white" />
              </div>
              <h1 class="text-2xl font-bold text-fg">Connect your machine</h1>
            </div>
            <p class="text-fg-secondary text-sm">Install the daemon to run agents locally.</p>
          </div>

          <div class="space-y-5">
            <%!-- Install --%>
            <div class="bg-surface-panel border border-border rounded-xl p-5 space-y-3">
              <div class="flex items-center gap-2">
                <span class="w-5 h-5 rounded-full bg-accent-indigo text-white text-xs font-bold flex items-center justify-center">
                  1
                </span>
                <h3 class="text-sm font-semibold text-fg">Install</h3>
              </div>
              <.copy_command cmd={"curl -fsSL #{@server_url}/install.sh | sh"} />
            </div>

            <%!-- Connect --%>
            <div class="bg-surface-panel border border-border rounded-xl p-5 space-y-3">
              <div class="flex items-center gap-2">
                <span class="w-5 h-5 rounded-full bg-accent-indigo text-white text-xs font-bold flex items-center justify-center">
                  2
                </span>
                <h3 class="text-sm font-semibold text-fg">Connect</h3>
              </div>
              <.copy_command cmd="ag login" />
            </div>

            <%!-- Status --%>
            <div class="flex items-center justify-center gap-3 py-2">
              <.daemon_status_indicator status={@daemon_status} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Components --

  defp step_dot(assigns) do
    ~H"""
    <div class={[
      "w-3 h-3 rounded-full transition-colors",
      @step == @current && "bg-accent-indigo",
      step_index(@step) < step_index(@current) && "bg-accent-indigo/50",
      step_index(@step) > step_index(@current) && "bg-border"
    ]} />
    """
  end

  defp copy_command(assigns) do
    ~H"""
    <div
      data-copy-container
      class="bg-surface-raised rounded-lg p-3 flex items-center justify-between gap-2 transition-all duration-300"
    >
      <code class="text-xs text-fg font-mono break-all">{@cmd}</code>
      <button
        type="button"
        phx-click={JS.dispatch("phx:copy", detail: %{text: @cmd})}
        class="shrink-0 p-1 text-fg-muted hover:text-fg transition-colors"
        title="Copy to clipboard"
      >
        <.icon name="hero-clipboard" class="size-4" />
      </button>
    </div>
    """
  end

  defp daemon_status_indicator(assigns) do
    ~H"""
    <div :if={@status == :waiting} class="flex items-center gap-2">
      <span class="w-2.5 h-2.5 rounded-full bg-fg-muted animate-pulse" />
      <span class="text-sm text-fg-muted">Waiting for daemon...</span>
    </div>
    <div :if={@status == :connected} class="flex items-center gap-2">
      <span class="w-2.5 h-2.5 rounded-full bg-green-500" />
      <span class="text-sm text-fg">Daemon connected!</span>
    </div>
    <div :if={@status == :repo_ready} class="flex items-center gap-2">
      <span class="w-2.5 h-2.5 rounded-full bg-green-500" />
      <.icon name="hero-check" class="size-4 text-green-500" />
      <span class="text-sm text-fg">Repository cloned and ready</span>
    </div>
    """
  end

  defp step_index(:workspace), do: 0
  defp step_index(:daemon), do: 1

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

  # -- Events --

  @impl true
  def handle_event("os_detected", %{"platform" => platform, "user_agent" => ua}, socket) do
    os = detect_os(platform, ua)
    {:noreply, assign(socket, :os, os)}
  end

  def handle_event("search_repos", %{"repo_search" => query}, socket) do
    {:noreply, assign(socket, :repo_search, query)}
  end

  def handle_event("select_repo", %{"url" => url, "name" => name}, socket) do
    {:noreply,
     assign(socket,
       github_repo_url: url,
       workspace_name: name,
       repo_dropdown_open: false,
       repo_search: ""
     )}
  end

  def handle_event("open_repo_dropdown", _params, socket) do
    {:noreply, assign(socket, repo_dropdown_open: true, repo_search: "")}
  end

  def handle_event("toggle_url_input", _params, socket) do
    {:noreply,
     assign(socket,
       show_url_input: !socket.assigns.show_url_input,
       repo_dropdown_open: false
     )}
  end

  def handle_event("create_workspace", %{"workspace" => params}, socket) do
    user = socket.assigns.current_user
    name = params["name"] || ""
    slug = slugify(name)
    prefix = Workspaces.prefix_for_name(name)

    repo_url =
      case String.trim(params["github_repo_url"] || socket.assigns.github_repo_url || "") do
        "" -> nil
        url -> url
      end

    attrs = %{name: name, slug: slug, prefix: prefix, github_repo_url: repo_url}

    case Workspaces.create_workspace(attrs) do
      {:ok, workspace} ->
        Workspaces.ensure_membership(workspace, user, role: :owner)
        create_default_automation(workspace)

        if connected?(socket), do: Daemons.subscribe(workspace.id)

        {:noreply,
         socket
         |> assign(:workspace, workspace)
         |> init_daemon_step()}

      {:error, _changeset} ->
        {:noreply, assign(socket, error: "Could not create workspace. Try a different name.")}
    end
  end

  # -- PubSub --

  @impl true
  def handle_info({:daemon_status_changed, daemon}, socket) do
    handle_daemon_update(socket, daemon)
  end

  def handle_info({:daemon_heartbeat, daemon}, socket) do
    handle_daemon_update(socket, daemon)
  end

  def handle_info({:repo_clone_status, _daemon_name, ws_slug, payload}, socket) do
    onboarding_slug = socket.assigns[:workspace] && socket.assigns.workspace.slug

    if payload["status"] == "ready" && ws_slug == onboarding_slug &&
         socket.assigns.step == :daemon do
      Process.send_after(self(), :auto_advance, 800)
      {:noreply, assign(socket, :daemon_status, :repo_ready)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:auto_advance, socket) do
    if socket.assigns.step == :daemon do
      workspace = socket.assigns.workspace
      create_starter_ticket(workspace)
      {:noreply, push_navigate(socket, to: ~p"/w/#{workspace.slug}/tickets")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp handle_daemon_update(socket, daemon) do
    if socket.assigns.workspace && daemon.status == :online &&
         socket.assigns.step == :daemon do
      ws_slug = socket.assigns.workspace.slug

      new_status =
        if Daemons.repo_ready?(daemon.name, ws_slug), do: :repo_ready, else: :connected

      Process.send_after(self(), :auto_advance, 1200)
      {:noreply, assign(socket, :daemon_status, new_status)}
    else
      {:noreply, socket}
    end
  end

  # -- Helpers --

  defp create_starter_ticket(workspace) do
    attrs = %{
      "title" => "Set up Algedonia configuration",
      "type" => "chore",
      "priority" => "3",
      "description" =>
        "Initialize the `.algedonia/` directory with project configuration files " <>
          "for Algedonia orchestration.\n\nWhen this ticket completes, an automation " <>
          "will automatically create a branch, open a PR with your changes, and post " <>
          "the PR link as a comment.",
      "acceptance_criteria" =>
        "The `.algedonia/` directory exists with a `rubrics.md` file containing " <>
          "initial code quality rubrics, and a `knowledge.md` file with basic project context.",
      "rubric" =>
        "- `.algedonia/` directory exists at the repo root\n" <>
          "- `rubrics.md` contains meaningful code quality guidelines (not placeholder text)\n" <>
          "- `knowledge.md` contains basic project context derived from the repo\n" <>
          "- No existing files are modified or deleted\n" <>
          "- Files use proper markdown formatting"
    }

    Tickets.create_ticket_for_workspace(workspace, attrs)
  end

  defp create_default_automation(workspace) do
    Workspaces.create_transition_hook(workspace, %{
      "from_status" => "in_progress",
      "to_status" => "completed",
      "instruction" => """
      Create a new git branch named after the ticket.
      Commit all changes to that branch.
      Push the branch and create a pull request.
      Verify that the CI passes.
      Add a comment to the ticket with the PR URL using `ag` CLI.
      """,
      "enabled" => true
    })
  end

  defp detect_os(platform, ua) do
    platform_lower = String.downcase(platform)
    ua_lower = String.downcase(ua)
    os = detect_os_family(platform_lower, ua_lower)
    arch = detect_arch(platform_lower, ua_lower)

    if os, do: "#{os}_#{arch}", else: nil
  end

  defp detect_os_family(platform, ua) do
    cond do
      String.contains?(platform, "mac") || String.contains?(ua, "macintosh") -> "darwin"
      String.contains?(platform, "linux") || String.contains?(ua, "linux") -> "linux"
      true -> nil
    end
  end

  defp detect_arch(platform, ua) do
    if String.contains?(ua, "arm64") || String.contains?(ua, "aarch64") ||
         String.contains?(platform, "arm"),
       do: "arm64",
       else: "amd64"
  end
end
