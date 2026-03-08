defmodule AlgedoniaWeb.SkillsLiveTest do
  use AlgedoniaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Algedonia.Skills

  describe "skills catalog" do
    test "renders seeded valid+invalid entries with required metadata columns", %{
      conn: conn,
      workspace: workspace
    } do
      root = make_skills_root!()

      _ =
        write_skill!(
          root,
          "command",
          """
          ---
          name: command
          description: Run shell command
          type: checker
          ---
          Body
          """
        )

      _ =
        write_skill!(
          root,
          "broken",
          """
          ---
          name broken
          description: malformed
          ---
          Body
          """
        )

      with_skills_root(root, fn ->
        payload = Skills.catalog()
        {:ok, _view, html} = live(conn, ~p"/w/#{workspace.slug}/skills")

        assert html =~ "Name"
        assert html =~ "Type"
        assert html =~ "Source Path"
        assert html =~ "Validation Status"

        Enum.each(payload.entries, fn entry ->
          assert html =~ entry.name
          assert html =~ entry.type
          assert html =~ entry.source_path
          assert html =~ String.capitalize(entry.validation_status)
        end)
      end)
    end

    test "marks invalid entries and shows actionable diagnostics with context", %{
      conn: conn,
      workspace: workspace
    } do
      root = make_skills_root!()

      _ =
        write_skill!(
          root,
          "valid",
          """
          ---
          name: valid
          description: OK
          type: checker
          ---
          Body
          """
        )

      broken_path =
        write_skill!(
          root,
          "missing-description",
          """
          ---
          name: missing-description
          type: checker
          ---
          Body
          """
        )

      with_skills_root(root, fn ->
        {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/skills")

        assert html =~ "missing-description"
        assert html =~ "Invalid"
        assert html =~ "Diagnostics"
        assert html =~ "Missing required field description"
        assert html =~ "Field: description"
        assert html =~ "File: #{broken_path}"
        assert html =~ "(checker)"

        assert has_element?(
                 view,
                 "#planning-skill-selector input[phx-value-skill='missing-description'][disabled]"
               )

        assert has_element?(
                 view,
                 "#checker-skill-selector input[phx-value-skill='missing-description'][disabled]"
               )

        assert has_element?(
                 view,
                 "#planning-skill-selector",
                 "Missing required field description"
               )

        assert has_element?(view, "#checker-skill-selector", "Missing required field description")

        view
        |> element("#planning-skill-selector input[phx-value-skill='valid']")
        |> render_click()

        assert has_element?(
                 view,
                 "#planning-skill-selector input[phx-value-skill='valid'][checked]"
               )
      end)
    end

    test "planner/checker selectors share catalog source and degraded mode disables controls", %{
      conn: conn,
      workspace: workspace
    } do
      root = make_skills_root!()

      _ =
        write_skill!(
          root,
          "browser-check",
          """
          ---
          name: browser-check
          description: Browser checks
          type: checker
          ---
          Body
          """
        )

      with_skills_root(root, fn ->
        {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/skills")

        assert has_element?(
                 view,
                 "#planning-skill-selector input[phx-value-skill='browser-check']"
               )

        assert has_element?(
                 view,
                 "#checker-skill-selector input[phx-value-skill='browser-check']"
               )

        view
        |> element("#planning-skill-selector input[phx-value-skill='browser-check']")
        |> render_click()

        assert has_element?(
                 view,
                 "#planning-skill-selector input[phx-value-skill='browser-check'][checked]"
               )
      end)

      missing_root =
        Path.join(
          System.tmp_dir!(),
          "algedonia-live-missing-#{System.unique_integer([:positive])}"
        )

      with_skills_root(missing_root, fn ->
        {:ok, view, html} = live(conn, ~p"/w/#{workspace.slug}/skills")

        assert html =~ "Skills catalog unavailable"
        assert html =~ "Skills directory not found"
        assert has_element?(view, "button[phx-click='retry_catalog']")
        assert has_element?(view, "#planning-skill-selector[disabled]")
        assert has_element?(view, "#checker-skill-selector[disabled]")

        view
        |> element("button[phx-click='retry_catalog']")
        |> render_click()

        assert has_element?(view, "#planning-skill-selector[disabled]")
        assert has_element?(view, "#checker-skill-selector[disabled]")
      end)
    end
  end

  defp with_skills_root(root, fun) when is_binary(root) and is_function(fun, 0) do
    previous = Application.get_env(:algedonia, :skills_root)
    Application.put_env(:algedonia, :skills_root, root)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:algedonia, :skills_root)
      else
        Application.put_env(:algedonia, :skills_root, previous)
      end
    end
  end

  defp make_skills_root! do
    root =
      Path.join(System.tmp_dir!(), "algedonia-live-skills-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp write_skill!(root, skill_dir, content) do
    dir = Path.join(root, skill_dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, String.trim_leading(content))
    path
  end
end
