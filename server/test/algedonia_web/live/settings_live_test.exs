defmodule AlgedoniaWeb.SettingsLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders settings page with workspace name", %{conn: conn, workspace: workspace} do
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      assert html =~ "Settings"
      assert html =~ workspace.name
      assert html =~ "Default iteration budget"
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

      html =
        view
        |> form("form[phx-submit=save]",
          workspace: %{
            name: workspace.name,
            github_repo_url: "https://github.com/org/repo",
            max_iterations: 9
          }
        )
        |> render_submit()

      assert html =~ "https://github.com/org/repo"
      assert Algedonia.Workspaces.get_workspace!(workspace.id).max_iterations == 9
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

  describe "automations" do
    test "renders automations section", %{conn: conn, workspace: workspace} do
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      assert html =~ "Automations"
      assert html =~ "No automations configured"
    end

    test "add automation button shows form", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      html =
        view
        |> element("button[phx-click=show_hook_form]")
        |> render_click()

      assert html =~ "From status"
      assert html =~ "To status"
      assert html =~ "Instruction"
    end

    test "creates a hook and shows it in the list", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      view
      |> element("button[phx-click=show_hook_form]")
      |> render_click()

      view
      |> form("form[phx-submit=save_hook]",
        hook: %{from_status: "backlog", to_status: "planning", instruction: "Run all tests"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Backlog"
      assert html =~ "Planning"
      assert html =~ "Run all tests"
    end

    test "deletes a hook", %{conn: conn, workspace: workspace} do
      {:ok, _hook} =
        Algedonia.Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run tests"
        })

      {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      assert html =~ "Run tests"

      view
      |> element("button[phx-click=delete_hook]")
      |> render_click()

      refute render(view) =~ "Run tests"
    end

    test "edits an existing hook", %{conn: conn, workspace: workspace} do
      {:ok, hook} =
        Algedonia.Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Initial instruction"
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      view
      |> element("button[phx-click=edit_hook][phx-value-id='#{hook.id}']")
      |> render_click()

      view
      |> form("form[phx-submit=update_hook]",
        hook: %{
          from_status: "planning",
          to_status: "in_progress",
          instruction: "Updated instruction with more detail"
        }
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Planning"
      assert html =~ "In Progress"
      assert html =~ "Updated instruction with more detail"
      refute html =~ "Initial instruction"
    end

    test "renders instruction text with wrapping styles (not truncate)", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, _hook} =
        Algedonia.Workspaces.create_transition_hook(workspace, %{
          "from_status" => "in_progress",
          "to_status" => "completed",
          "instruction" => "First line\nSecond line with extra detail"
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      assert has_element?(view, "p.whitespace-pre-wrap.break-words", "First line")
      assert render(view) =~ "Second line with extra detail"
    end

    test "rejects duplicate from/to pair", %{conn: conn, workspace: workspace} do
      {:ok, _hook} =
        Algedonia.Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "First"
        })

      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      view
      |> element("button[phx-click=show_hook_form]")
      |> render_click()

      view
      |> form("form[phx-submit=save_hook]",
        hook: %{from_status: "backlog", to_status: "planning", instruction: "Duplicate"}
      )
      |> render_submit()

      # The duplicate should have been rejected, only one hook with "First" should exist
      hooks = Algedonia.Workspaces.list_transition_hooks(workspace.id)
      assert length(hooks) == 1
      assert hd(hooks).instruction == "First"
    end
  end
end
