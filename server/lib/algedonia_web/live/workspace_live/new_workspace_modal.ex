defmodule AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal do
  @moduledoc """
  Shared event handlers for the new workspace modal.

  `use` this module in any LiveView that needs the "New workspace" modal.
  It injects `handle_event` callbacks for opening, closing, validating,
  and submitting the new workspace form.

  Requires the socket to have `:show_new_workspace_modal`, `:current_user`,
  and `:new_workspace_form` assigns (the latter is set automatically).
  """

  defmacro __using__(_opts) do
    quote do
      @impl true
      def handle_event("open_new_workspace_modal", _params, socket) do
        changeset = Algedonia.Workspaces.change_workspace(%Algedonia.Workspaces.Workspace{})

        {:noreply,
         socket
         |> assign(:show_new_workspace_modal, true)
         |> assign(:new_workspace_form, to_form(changeset))}
      end

      @impl true
      def handle_event("close_new_workspace_modal", _params, socket) do
        {:noreply, assign(socket, :show_new_workspace_modal, false)}
      end

      @impl true
      def handle_event("validate_new_workspace", %{"workspace" => params}, socket) do
        changeset =
          %Algedonia.Workspaces.Workspace{}
          |> Algedonia.Workspaces.change_workspace(params)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :new_workspace_form, to_form(changeset))}
      end

      @impl true
      def handle_event("create_new_workspace", %{"workspace" => %{"name" => name}}, socket) do
        user = socket.assigns.current_user
        slug = AlgedoniaWeb.Helpers.slugify(name)
        prefix = Algedonia.Workspaces.prefix_for_name(name)

        case Algedonia.Workspaces.create_workspace(%{name: name, slug: slug, prefix: prefix}) do
          {:ok, workspace} ->
            Algedonia.Workspaces.ensure_membership(workspace, user)

            {:noreply,
             socket
             |> assign(:show_new_workspace_modal, false)
             |> push_navigate(to: "/w/#{workspace.slug}/tickets")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Could not create workspace. Try a different name.")}
        end
      end
    end
  end
end
