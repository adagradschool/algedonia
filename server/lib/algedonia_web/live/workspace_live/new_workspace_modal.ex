defmodule AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal do
  @moduledoc """
  Shared event handlers for the new workspace modal.

  `use` this module in any LiveView that needs the "New workspace" modal.
  It injects `handle_event` callbacks for opening, closing, validating,
  and submitting the new workspace form, including a GitHub repo picker.

  Requires the socket to have `:show_new_workspace_modal`, `:current_user`,
  `:github_token`, and `:new_workspace_form` assigns (the latter is set automatically).
  """

  defmacro __using__(_opts) do
    quote do
      alias Algedonia.Workspaces
      alias Algedonia.Workspaces.Workspace
      alias AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

      @impl true
      def handle_event("open_new_workspace_modal", _params, socket) do
        changeset = Workspaces.change_workspace(%Workspace{})
        repos = NewWorkspaceModal.fetch_repos(socket)

        {:noreply,
         socket
         |> assign(:show_new_workspace_modal, true)
         |> assign(:new_workspace_form, to_form(changeset))
         |> assign(:new_ws_repos, repos)
         |> assign(:new_ws_repo_search, "")
         |> assign(:new_ws_repo_dropdown_open, false)
         |> assign(:new_ws_github_repo_url, nil)
         |> assign(:new_ws_workspace_name, nil)
         |> assign(:new_ws_show_url_input, repos == [])}
      end

      @impl true
      def handle_event("close_new_workspace_modal", _params, socket) do
        {:noreply, assign(socket, :show_new_workspace_modal, false)}
      end

      @impl true
      def handle_event("validate_new_workspace", %{"workspace" => params}, socket) do
        changeset =
          %Workspace{}
          |> Workspaces.change_workspace(NewWorkspaceModal.workspace_attrs(params, socket))
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :new_workspace_form, to_form(changeset))}
      end

      @impl true
      def handle_event("new_ws_search_repos", %{"repo_search" => query}, socket) do
        {:noreply, assign(socket, :new_ws_repo_search, query)}
      end

      @impl true
      def handle_event("new_ws_select_repo", %{"url" => url, "name" => name}, socket) do
        {:noreply,
         assign(socket,
           new_ws_github_repo_url: url,
           new_ws_workspace_name: name,
           new_ws_repo_dropdown_open: false,
           new_ws_repo_search: ""
         )}
      end

      @impl true
      def handle_event("new_ws_open_repo_dropdown", _params, socket) do
        {:noreply, assign(socket, new_ws_repo_dropdown_open: true, new_ws_repo_search: "")}
      end

      @impl true
      def handle_event("new_ws_toggle_url_input", _params, socket) do
        {:noreply,
         assign(socket,
           new_ws_show_url_input: !socket.assigns.new_ws_show_url_input,
           new_ws_repo_dropdown_open: false
         )}
      end

      @impl true
      def handle_event("create_new_workspace", %{"workspace" => params}, socket) do
        user = socket.assigns.current_user
        attrs = NewWorkspaceModal.workspace_attrs(params, socket)

        case Workspaces.create_workspace(attrs) do
          {:ok, workspace} ->
            Workspaces.ensure_membership(workspace, user)

            {:noreply,
             socket
             |> assign(:show_new_workspace_modal, false)
             |> push_navigate(to: "/w/#{workspace.slug}/tickets")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:show_new_workspace_modal, true)
             |> assign(:new_workspace_form, to_form(changeset))}
        end
      end
    end
  end

  alias Algedonia.Accounts.GitHub

  @doc false
  def fetch_repos(socket) do
    case socket.assigns[:github_token] do
      nil ->
        []

      "" ->
        []

      token ->
        case GitHub.list_user_repos(token) do
          {:ok, repos} -> repos
          {:error, _} -> []
        end
    end
  end

  @doc false
  def workspace_attrs(params, socket) do
    name = params["name"] || ""
    slug = AlgedoniaWeb.Helpers.slugify(name)
    prefix = Algedonia.Workspaces.prefix_for_name(name)

    repo_url =
      case String.trim(params["github_repo_url"] || socket.assigns[:new_ws_github_repo_url] || "") do
        "" -> nil
        url -> url
      end

    %{name: name, slug: slug, prefix: prefix, github_repo_url: repo_url}
  end
end
