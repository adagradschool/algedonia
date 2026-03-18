defmodule AlgedoniaWeb.SettingsLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders settings page with workspace name", %{conn: conn, workspace: workspace} do
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      assert html =~ "Settings"
      assert html =~ workspace.name
      assert html =~ "Default iteration budget"
      assert html =~ "Worktree bootstrap script"
      assert html =~ "Worktree manual run script"
    end

    test "renders script fields as code editors with shell highlighting", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      assert has_element?(view, "#settings-scroll-container.flex-1.min-h-0.overflow-y-auto")
      assert has_element?(view, "#settings-content.max-w-2xl.space-y-8")

      assert has_element?(
               view,
               "#settings-scroll-container > #settings-content"
             )

      refute has_element?(
               view,
               "#settings-scroll-container.max-w-2xl"
             )

      assert has_element?(
               view,
               "#bootstrap-script-editor .script-editor-shell.script-editor-shell--bounded"
             )

      assert has_element?(
               view,
               "div[phx-hook=ScriptEditor] textarea#workspace_worktree_bootstrap_script.script-editor-input.script-editor-input--scrollable[data-role=source]"
             )

      assert has_element?(
               view,
               "#run-script-editor .script-editor-shell.script-editor-shell--bounded"
             )

      assert has_element?(
               view,
               "div[phx-hook=ScriptEditor] textarea#workspace_worktree_run_script.script-editor-input.script-editor-input--scrollable[data-role=source]"
             )

      assert has_element?(
               view,
               "div[phx-hook=ScriptEditor] code.language-bash[data-role=highlight]"
             )

      html = render(view)
      assert html |> String.split("phx-hook=\"ScriptEditor\"") |> length() == 3
      assert html |> String.split("data-role=\"drop-error\"") |> length() == 3
    end

    test "long script content keeps bounded editors and lower settings content rendered", %{
      conn: conn,
      workspace: workspace
    } do
      long_bootstrap =
        1..40
        |> Enum.map_join("\n", &"echo bootstrap line #{&1}")

      long_run =
        1..40
        |> Enum.map_join("\n", &"./script/run_step_#{&1}.sh")

      {:ok, workspace} =
        Algedonia.Workspaces.update_workspace(workspace, %{
          worktree_bootstrap_script: long_bootstrap,
          worktree_run_script: long_run
        })

      {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      assert has_element?(view, "#settings-scroll-container")
      assert has_element?(view, "#settings-content.max-w-2xl")
      assert has_element?(view, "#bootstrap-script-editor .script-editor-shell--bounded")
      assert has_element?(view, "#run-script-editor .script-editor-shell--bounded")
      assert html =~ "echo bootstrap line 40"
      assert html =~ "./script/run_step_40.sh"
      assert html =~ "Invite member"
      assert html =~ "Automations"
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

    test "submitted prefix is ignored and remains derived from the workspace name", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      view
      |> form("form[phx-submit=save]",
        workspace: %{
          name: "Derived Prefix Workspace",
          prefix: "MANUAL"
        }
      )
      |> render_submit()

      flash = assert_redirect(view, ~p"/w/derived-prefix-workspace/settings")
      assert flash["info"] == "Workspace updated."

      reloaded = Algedonia.Workspaces.get_workspace!(workspace.id)
      assert reloaded.prefix == Algedonia.Workspaces.prefix_for_name("Derived Prefix Workspace")
      refute reloaded.prefix == "MANUAL"
    end

    test "stays on same page when slug unchanged", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      html =
        view
        |> form("form[phx-submit=save]",
          workspace: %{
            name: workspace.name,
            github_repo_url: "https://github.com/org/repo",
            max_iterations: 9,
            worktree_bootstrap_script: "scripts/bootstrap.sh",
            worktree_run_script: "scripts/verify.sh"
          }
        )
        |> render_submit()

      assert html =~ "https://github.com/org/repo"
      assert Algedonia.Workspaces.get_workspace!(workspace.id).max_iterations == 9

      assert Algedonia.Workspaces.get_workspace!(workspace.id).worktree_bootstrap_script ==
               "scripts/bootstrap.sh"

      assert Algedonia.Workspaces.get_workspace!(workspace.id).worktree_run_script ==
               "scripts/verify.sh"
    end

    test "manual typing in script fields persists as before", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      script_params = %{
        worktree_bootstrap_script: "echo boot\n./bootstrap.sh",
        worktree_run_script: "echo run\n./run.sh"
      }

      html =
        view
        |> form("form[phx-submit=save]", workspace: script_params)
        |> render_change()

      assert html =~ "echo boot"
      assert html =~ "./run.sh"

      view
      |> form("form[phx-submit=save]", workspace: script_params)
      |> render_submit()

      reloaded = Algedonia.Workspaces.get_workspace!(workspace.id)
      assert reloaded.worktree_bootstrap_script == script_params.worktree_bootstrap_script
      assert reloaded.worktree_run_script == script_params.worktree_run_script
    end

    test "single-file drop replacement syncs and persists exact script content", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      dropped_bootstrap = "#!/usr/bin/env bash\nset -euo pipefail\necho \"boot\"\n"
      dropped_run = "#!/usr/bin/env bash\n./scripts/check.sh --fast\n"

      html =
        view
        |> form("form[phx-submit=save]",
          workspace: %{
            worktree_bootstrap_script: dropped_bootstrap,
            worktree_run_script: dropped_run
          }
        )
        |> render_change()

      assert html =~ "set -euo pipefail"
      assert html =~ "./scripts/check.sh --fast"

      view
      |> form("form[phx-submit=save]",
        workspace: %{
          worktree_bootstrap_script: dropped_bootstrap,
          worktree_run_script: dropped_run
        }
      )
      |> render_submit()

      reloaded = Algedonia.Workspaces.get_workspace!(workspace.id)
      assert reloaded.worktree_bootstrap_script == dropped_bootstrap
      assert reloaded.worktree_run_script == dropped_run

      {:ok, reloaded_view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      reloaded_html = render(reloaded_view)
      assert reloaded_html =~ "set -euo pipefail"
      assert reloaded_html =~ "./scripts/check.sh --fast"
    end

    test "rejects multi-file drop for bootstrap script and keeps save payload unchanged", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      assert has_element?(view, "#bootstrap-script-editor [data-role='drop-error'].hidden")

      view
      |> element("#bootstrap-script-editor")
      |> render_hook("script_drop_error", %{
        "field" => "worktree_bootstrap_script",
        "message" => "Drop exactly one text file."
      })

      assert has_element?(
               view,
               "#bootstrap-script-editor [data-role='drop-error']:not(.hidden)",
               "Drop exactly one text file."
             )

      original = Algedonia.Workspaces.get_workspace!(workspace.id)

      view
      |> form("form[phx-submit=save]",
        workspace: %{
          worktree_bootstrap_script: original.worktree_bootstrap_script || "",
          worktree_run_script: original.worktree_run_script || ""
        }
      )
      |> render_submit()

      persisted = Algedonia.Workspaces.get_workspace!(workspace.id)
      assert persisted.worktree_bootstrap_script == original.worktree_bootstrap_script
      assert persisted.worktree_run_script == original.worktree_run_script
    end

    test "read failure drop error for run script keeps value unchanged", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      view
      |> element("#run-script-editor")
      |> render_hook("script_drop_error", %{
        "field" => "worktree_run_script",
        "message" => "Could not read dropped file as text."
      })

      assert has_element?(
               view,
               "#run-script-editor [data-role='drop-error']:not(.hidden)",
               "Could not read dropped file as text."
             )

      original = Algedonia.Workspaces.get_workspace!(workspace.id)

      view
      |> form("form[phx-submit=save]",
        workspace: %{
          worktree_bootstrap_script: original.worktree_bootstrap_script || "",
          worktree_run_script: original.worktree_run_script || ""
        }
      )
      |> render_submit()

      persisted = Algedonia.Workspaces.get_workspace!(workspace.id)
      assert persisted.worktree_bootstrap_script == original.worktree_bootstrap_script
      assert persisted.worktree_run_script == original.worktree_run_script
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

  describe "default land mode" do
    test "renders land mode selector with default value", %{conn: conn, workspace: workspace} do
      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      assert html =~ "Default land mode"
      assert html =~ "Review Gate"
      assert html =~ "Auto Land"
    end

    test "saves default land mode to workspace defaults", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/settings")

      view
      |> form("form[phx-submit=save]",
        workspace: %{name: workspace.name, default_land_mode: "auto_land"}
      )
      |> render_submit()

      reloaded = Algedonia.Workspaces.get_workspace!(workspace.id)
      assert reloaded.defaults["land_mode"] == "auto_land"
    end

    test "persisted land mode is reflected on reload", %{conn: conn, workspace: workspace} do
      {:ok, _} =
        Algedonia.Workspaces.update_workspace(workspace, %{
          defaults: %{"land_mode" => "auto_land"}
        })

      {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/settings")
      assert html =~ ~s(value="auto_land" selected)
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
