defmodule AlgedoniaWeb.SettingsLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders settings page with workspace name", %{conn: conn, workspace: workspace} do
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      assert html =~ "Settings"
      assert html =~ workspace.name
    end
  end

  describe "validate" do
    test "validates form changes", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      html =
        view
        |> form("form[phx-submit=save]", workspace: %{name: ""})
        |> render_change()

      assert html =~ "be blank"
    end
  end

  describe "save" do
    test "updates workspace and redirects when slug changes", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      view
      |> form("form[phx-submit=save]", workspace: %{name: "Updated Name"})
      |> render_submit()

      flash = assert_redirect(view, ~p"/w/updated-name/settings")
      assert flash["info"] == "Workspace updated."
    end

    test "stays on same page when slug unchanged", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      view
      |> form("form[phx-submit=save]",
        workspace: %{name: workspace.name, github_repo_url: "https://github.com/org/repo"}
      )
      |> render_submit()

      assert render(view) =~ "https://github.com/org/repo"
    end
  end

  describe "invite" do
    test "creates invitation and shows flash", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      html =
        view
        |> form("form[phx-submit=invite]", invite: %{github_username: "newmember"})
        |> render_submit()

      assert html =~ "Invitation sent."
      assert html =~ "@newmember"
    end
  end

  describe "cancel_invitation" do
    test "cancels a pending invitation", %{conn: conn, workspace: workspace, user: user} do
      {:ok, _} = Algedonia.Workspaces.create_invitation(workspace, "someone", user)

      {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      assert html =~ "@someone"

      html =
        view
        |> element("button[phx-click=cancel_invitation]")
        |> render_click()

      assert html =~ "Invitation cancelled."
      refute html =~ "@someone"
    end
  end
end
