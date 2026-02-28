defmodule AlgedoniaWeb.SettingsLive.Index do
  @moduledoc """
  LiveView for workspace settings, members, and invitations.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  alias Algedonia.Workspaces

  import AlgedoniaWeb.Helpers, only: [slugify: 1]

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_workspace

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign_settings_form(workspace)
     |> assign_members_and_invitations(workspace)
     |> assign(:invite_form, to_form(%{"github_username" => ""}, as: "invite"))}
  end

  @impl true
  def handle_event("validate", %{"workspace" => params}, socket) do
    changeset =
      socket.assigns.current_workspace
      |> Workspaces.change_workspace(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"workspace" => params}, socket) do
    workspace = socket.assigns.current_workspace
    slug = slugify(params["name"] || workspace.name)
    params = Map.put(params, "slug", slug)
    prefix = Workspaces.prefix_for_name(params["name"] || workspace.name)
    params = Map.put(params, "prefix", prefix)

    case Workspaces.update_workspace(workspace, params) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(:current_workspace, updated)
          |> assign_settings_form(updated)
          |> put_flash(:info, "Workspace updated.")

        if updated.slug != workspace.slug do
          {:noreply, push_navigate(socket, to: "/w/#{updated.slug}/settings")}
        else
          {:noreply, socket}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("invite", %{"invite" => %{"github_username" => username}}, socket) do
    workspace = socket.assigns.current_workspace
    user = socket.assigns.current_user

    case Workspaces.create_invitation(workspace, username, user) do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> assign_members_and_invitations(workspace)
         |> assign(:invite_form, to_form(%{"github_username" => ""}, as: "invite"))
         |> put_flash(:info, "Invitation sent.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not send invitation.")}
    end
  end

  @impl true
  def handle_event("cancel_invitation", %{"id" => id}, socket) do
    case Workspaces.cancel_invitation(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_members_and_invitations(socket.assigns.current_workspace)
         |> put_flash(:info, "Invitation cancelled.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not cancel invitation.")}
    end
  end

  defp assign_settings_form(socket, workspace) do
    changeset = Workspaces.change_workspace(workspace)
    assign(socket, :form, to_form(changeset))
  end

  defp assign_members_and_invitations(socket, workspace) do
    socket
    |> assign(:members, Workspaces.list_members(workspace.id))
    |> assign(:invitations, Workspaces.list_invitations(workspace.id))
  end
end
