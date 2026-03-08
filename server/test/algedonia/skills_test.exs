defmodule Algedonia.SkillsTest do
  use ExUnit.Case, async: true

  alias Algedonia.Skills

  describe "load_registry/1" do
    test "loads valid skills and excludes invalid files with actionable errors" do
      root = make_skills_root!()

      write_skill!(
        root,
        "valid-skill",
        """
        ---
        name: valid-skill
        description: A valid skill
        params_schema: {"type":"string"}
        ---
        Runs a command.
        """
      )

      invalid_file =
        write_skill!(
          root,
          "missing-description",
          """
          ---
          name: missing-description
          ---
          Missing required fields.
          """
        )

      registry = Skills.load_registry(skills_root: root)

      assert [skill] = Skills.list_skills(skills_root: root)
      assert skill.name == "valid-skill"
      assert skill.file != invalid_file

      assert Enum.any?(registry.errors, fn error ->
               error.file == invalid_file and
                 error.field == "description" and
                 error.code == "missing_required_field" and
                 error.message =~ "Missing required field description"
             end)
    end

    test "returns a structured parse error for malformed frontmatter" do
      root = make_skills_root!()

      bad_file =
        write_skill!(
          root,
          "malformed",
          """
          ---
          name malformed
          description: bad
          ---
          Body
          """
        )

      registry = Skills.load_registry(skills_root: root)

      assert Enum.any?(registry.errors, fn error ->
               error.file == bad_file and
                 error.field == "frontmatter" and
                 error.code == "invalid_frontmatter_syntax" and
                 is_binary(error.message)
             end)
    end
  end

  describe "validate_checker_config/2" do
    test "accepts valid checker config against the shared invocation schema" do
      root = make_skills_root!()

      write_skill!(
        root,
        "command",
        """
        ---
        name: command
        description: Run a shell command
        params_schema: {"type":"string"}
        ---
        Command skill.
        """
      )

      write_skill!(
        root,
        "browser-check",
        """
        ---
        name: browser-check
        description: Run a browser scenario
        params_schema: {"type":"object","required":["scenario"],"properties":{"scenario":{"type":"string"}}}
        ---
        Browser skill.
        """
      )

      config = [
        %{"skill" => "command", "params" => "cd server && mix test"},
        %{"skill" => "browser-check", "params" => %{"scenario" => "visit / and verify"}}
      ]

      assert {:ok, [_first, _second], registry} =
               Skills.validate_checker_config(config, skills_root: root)

      assert registry.errors == []
    end

    test "returns index/path-aware errors for unknown skills and invalid params shapes" do
      root = make_skills_root!()

      write_skill!(
        root,
        "command",
        """
        ---
        name: command
        description: Run a shell command
        params_schema: {"type":"string"}
        ---
        Command skill.
        """
      )

      write_skill!(
        root,
        "browser-check",
        """
        ---
        name: browser-check
        description: Run a browser scenario
        params_schema: {"type":"object","required":["scenario"],"properties":{"scenario":{"type":"string"}}}
        ---
        Browser skill.
        """
      )

      config = [
        %{"skill" => "missing-skill", "params" => "x"},
        %{"skill" => "command", "params" => %{}},
        %{"skill" => "browser-check", "params" => %{}}
      ]

      assert {:error, errors, _registry} =
               Skills.validate_checker_config(config, skills_root: root)

      assert Enum.any?(
               errors,
               &(&1.code == "unknown_skill" and &1.path == "$[0].skill" and &1.index == 0)
             )

      assert Enum.any?(errors, fn error ->
               error.code == "invalid_params_shape" and
                 error.path == "$[1].params" and
                 error.index == 1
             end)

      assert Enum.any?(errors, fn error ->
               error.code == "missing_required_param" and
                 error.path == "$[2].params.scenario" and
                 error.index == 2
             end)

      mapped = Skills.errors_to_maps(errors)

      assert Enum.all?(mapped, fn payload ->
               Map.has_key?(payload, :file) and
                 Map.has_key?(payload, :field) and
                 Map.has_key?(payload, :path) and
                 Map.has_key?(payload, :index) and
                 Map.has_key?(payload, :code) and
                 Map.has_key?(payload, :message) and
                 is_binary(payload.code) and
                 is_binary(payload.message)
             end)
    end
  end

  defp make_skills_root! do
    root = Path.join(System.tmp_dir!(), "algedonia-skills-#{System.unique_integer([:positive])}")
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
