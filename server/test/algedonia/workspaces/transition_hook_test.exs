defmodule Algedonia.Workspaces.TransitionHookTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Workspaces
  alias Algedonia.Workspaces.TransitionHook

  import Algedonia.Factory

  describe "TransitionHook changeset" do
    test "valid changeset with all required fields" do
      workspace = default_workspace!()

      changeset =
        TransitionHook.changeset(%TransitionHook{}, %{
          workspace_id: workspace.id,
          from_status: :backlog,
          to_status: :planning,
          instruction: "Run linter on the codebase"
        })

      assert changeset.valid?
    end

    test "requires workspace_id" do
      changeset =
        TransitionHook.changeset(%TransitionHook{}, %{
          from_status: :backlog,
          to_status: :planning,
          instruction: "Run linter"
        })

      assert %{workspace_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires from_status" do
      changeset =
        TransitionHook.changeset(%TransitionHook{}, %{
          workspace_id: 1,
          to_status: :planning,
          instruction: "Run linter"
        })

      assert %{from_status: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires to_status" do
      changeset =
        TransitionHook.changeset(%TransitionHook{}, %{
          workspace_id: 1,
          from_status: :backlog,
          instruction: "Run linter"
        })

      assert %{to_status: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires instruction" do
      changeset =
        TransitionHook.changeset(%TransitionHook{}, %{
          workspace_id: 1,
          from_status: :backlog,
          to_status: :planning
        })

      assert %{instruction: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates from_status against allowed values" do
      changeset =
        TransitionHook.changeset(%TransitionHook{}, %{
          workspace_id: 1,
          from_status: :invalid,
          to_status: :planning,
          instruction: "Run linter"
        })

      assert %{from_status: [_]} = errors_on(changeset)
    end

    test "validates to_status against allowed values" do
      changeset =
        TransitionHook.changeset(%TransitionHook{}, %{
          workspace_id: 1,
          from_status: :backlog,
          to_status: :invalid,
          instruction: "Run linter"
        })

      assert %{to_status: [_]} = errors_on(changeset)
    end

    test "defaults enabled to true" do
      changeset =
        TransitionHook.changeset(%TransitionHook{}, %{
          workspace_id: 1,
          from_status: :backlog,
          to_status: :planning,
          instruction: "Run linter"
        })

      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end
  end

  describe "CRUD operations" do
    test "create_transition_hook/2 inserts a hook" do
      workspace = default_workspace!()

      assert {:ok, hook} =
               Workspaces.create_transition_hook(workspace, %{
                 "from_status" => "backlog",
                 "to_status" => "planning",
                 "instruction" => "Run tests"
               })

      assert hook.from_status == :backlog
      assert hook.to_status == :planning
      assert hook.instruction == "Run tests"
      assert hook.workspace_id == workspace.id
    end

    test "create_transition_hook/2 enforces unique constraint" do
      workspace = default_workspace!()

      attrs = %{
        "from_status" => "backlog",
        "to_status" => "planning",
        "instruction" => "Run tests"
      }

      assert {:ok, _} = Workspaces.create_transition_hook(workspace, attrs)

      assert {:error, changeset} =
               Workspaces.create_transition_hook(workspace, Map.put(attrs, "instruction", "Lint"))

      assert errors_on(changeset)[:workspace_id] != nil ||
               errors_on(changeset)[:from_status] != nil
    end

    test "update_transition_hook/2 updates fields" do
      workspace = default_workspace!()

      {:ok, hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Original"
        })

      assert {:ok, updated} =
               Workspaces.update_transition_hook(hook, %{"instruction" => "Updated"})

      assert updated.instruction == "Updated"
    end

    test "delete_transition_hook/1 removes the hook" do
      workspace = default_workspace!()

      {:ok, hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run tests"
        })

      assert {:ok, _} = Workspaces.delete_transition_hook(hook)
      assert Workspaces.get_transition_hook(hook.id) == nil
    end
  end

  describe "get_hooks_for_transition/3" do
    test "returns matching enabled hooks" do
      workspace = default_workspace!()

      {:ok, _} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run tests"
        })

      {:ok, _} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "planning",
          "to_status" => "in_progress",
          "instruction" => "Run lint"
        })

      hooks = Workspaces.get_hooks_for_transition(workspace.id, :backlog, :planning)
      assert length(hooks) == 1
      assert hd(hooks).instruction == "Run tests"
    end

    test "excludes disabled hooks" do
      workspace = default_workspace!()

      {:ok, hook} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "Run tests"
        })

      {:ok, _} = Workspaces.update_transition_hook(hook, %{"enabled" => false})

      assert Workspaces.get_hooks_for_transition(workspace.id, :backlog, :planning) == []
    end

    test "returns empty list when no hooks match" do
      workspace = default_workspace!()
      assert Workspaces.get_hooks_for_transition(workspace.id, :backlog, :planning) == []
    end
  end

  describe "list_transition_hooks/1" do
    test "returns hooks sorted by stage progression" do
      workspace = default_workspace!()

      {:ok, _} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "in_progress",
          "to_status" => "completed",
          "instruction" => "Second"
        })

      {:ok, _} =
        Workspaces.create_transition_hook(workspace, %{
          "from_status" => "backlog",
          "to_status" => "planning",
          "instruction" => "First"
        })

      hooks = Workspaces.list_transition_hooks(workspace.id)
      assert length(hooks) == 2
      assert hd(hooks).instruction == "First"
      assert List.last(hooks).instruction == "Second"
    end
  end
end
