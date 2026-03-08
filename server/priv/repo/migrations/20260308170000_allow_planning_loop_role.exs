defmodule Algedonia.Repo.Migrations.AllowPlanningLoopRole do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE loops DROP CONSTRAINT IF EXISTS loops_role_check")

    execute(
      "ALTER TABLE loops ADD CONSTRAINT loops_role_check CHECK (role IN ('task', 'hook', 'planning'))"
    )
  end

  def down do
    execute("ALTER TABLE loops DROP CONSTRAINT IF EXISTS loops_role_check")

    execute("ALTER TABLE loops ADD CONSTRAINT loops_role_check CHECK (role IN ('task', 'hook'))")
  end
end
