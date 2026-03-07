defmodule Algedonia.Repo.Migrations.AddWorkspaceConfigsAndMembershipRoles do
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      add :tracker_config, :map, null: false, default: %{}
      add :playback_config, :map, null: false, default: %{}
      add :defaults, :map, null: false, default: %{}
      add :planning_mode, :text, null: false, default: "auto"
    end

    execute(
      """
      ALTER TABLE workspaces
      ADD CONSTRAINT workspaces_planning_mode_check
      CHECK (planning_mode IN ('auto', 'always_approve', 'always_review'))
      """,
      "ALTER TABLE workspaces DROP CONSTRAINT IF EXISTS workspaces_planning_mode_check"
    )

    execute("ALTER TABLE workspace_memberships DROP CONSTRAINT IF EXISTS valid_role")

    execute(
      """
      ALTER TABLE workspace_memberships
      ADD CONSTRAINT valid_role
      CHECK (role IN ('owner', 'member'))
      """,
      "ALTER TABLE workspace_memberships DROP CONSTRAINT IF EXISTS valid_role"
    )
  end

  def down do
    execute("ALTER TABLE workspace_memberships DROP CONSTRAINT IF EXISTS valid_role")

    execute(
      "ALTER TABLE workspace_memberships ADD CONSTRAINT valid_role CHECK (role IN ('member'))"
    )

    execute("ALTER TABLE workspaces DROP CONSTRAINT IF EXISTS workspaces_planning_mode_check")

    alter table(:workspaces) do
      remove :planning_mode
      remove :defaults
      remove :playback_config
      remove :tracker_config
    end
  end
end
