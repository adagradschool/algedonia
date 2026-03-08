defmodule Algedonia.SkillsCatalogTest do
  use ExUnit.Case, async: true

  alias Algedonia.Skills

  describe "catalog/1" do
    test "returns valid and invalid entries with diagnostics" do
      root = make_skills_root!()

      valid_path =
        write_skill!(
          root,
          "browser-check",
          """
          ---
          name: browser-check
          description: Verify browser journey
          type: checker
          ---
          Body
          """
        )

      invalid_path =
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

      payload = Skills.catalog(skills_root: root)

      assert payload.load_error == nil

      assert Enum.any?(payload.entries, fn entry ->
               entry.name == "browser-check" and
                 entry.type == "checker" and
                 entry.source_path == valid_path and
                 entry.validation_status == "valid" and
                 entry.diagnostics == []
             end)

      assert Enum.any?(payload.entries, fn entry ->
               entry.name == "broken" and
                 entry.type == "unknown" and
                 entry.source_path == invalid_path and
                 entry.validation_status == "invalid" and
                 Enum.any?(entry.diagnostics, fn diagnostic ->
                   diagnostic.code == "invalid_frontmatter_syntax" and
                     diagnostic.message =~ "line"
                 end)
             end)
    end

    test "surfaces load_error when skills root is missing" do
      missing_root =
        Path.join(
          System.tmp_dir!(),
          "algedonia-skills-missing-#{System.unique_integer([:positive])}"
        )

      payload = Skills.catalog(skills_root: missing_root)

      assert payload.entries == []
      assert payload.load_error.code == "skills_dir_not_found"
      assert payload.load_error.source_path == Path.expand(missing_root)
      assert payload.load_error.message =~ "Skills directory not found"
    end
  end

  defp make_skills_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "algedonia-skills-catalog-#{System.unique_integer([:positive])}"
      )

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
