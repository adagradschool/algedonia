defmodule AlgedoniaWeb.SettingsLive.Index do
  @moduledoc """
  LiveView for workspace settings, members, and invitations.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  alias Algedonia.Workspaces

  import AlgedoniaWeb.Helpers, only: [slugify: 1]

  @script_fields ~w(worktree_bootstrap_script worktree_run_script)

  @impl true
  def mount(_params, _session, socket) do
    workspace = socket.assigns.current_workspace

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:script_drop_errors, %{})
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

    {:noreply, socket |> assign(:form, to_form(changeset)) |> clear_script_drop_errors()}
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
          |> clear_script_drop_errors()
          |> put_flash(:info, "Workspace updated.")

        if updated.slug != workspace.slug do
          {:noreply, push_navigate(socket, to: "/w/#{updated.slug}/settings")}
        else
          {:noreply, socket}
        end

      {:error, changeset} ->
        {:noreply, socket |> assign(:form, to_form(changeset)) |> clear_script_drop_errors()}
    end
  end

  @impl true
  def handle_event("script_drop_error", %{"field" => field} = params, socket) do
    message = Map.get(params, "message")

    if field in @script_fields do
      {:noreply, put_script_drop_error(socket, field, message)}
    else
      {:noreply, socket}
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

  defp put_script_drop_error(socket, field, message) when message in [nil, ""] do
    assign(socket, :script_drop_errors, Map.delete(socket.assigns.script_drop_errors, field))
  end

  defp put_script_drop_error(socket, field, message) do
    assign(
      socket,
      :script_drop_errors,
      Map.put(socket.assigns.script_drop_errors, field, message)
    )
  end

  defp clear_script_drop_errors(socket), do: assign(socket, :script_drop_errors, %{})
end
