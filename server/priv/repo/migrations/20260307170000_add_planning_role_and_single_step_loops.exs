defmodule Algedonia.Repo.Migrations.AddPlanningRoleAndSingleStepLoops do
  use Ecto.Migration

  def up do
    # Expand loops.role to include 'planning'
    execute "ALTER TABLE loops DROP CONSTRAINT loops_role_check"

    execute "ALTER TABLE loops ADD CONSTRAINT loops_role_check CHECK (role IN ('task', 'hook', 'planning'))"

    # Expand loop_steps.role to include 'hook' and 'planning'
    execute "ALTER TABLE loop_steps DROP CONSTRAINT loop_steps_role_check"

    execute "ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_role_check CHECK (role IN ('maker', 'checker', 'hook', 'planning'))"
  end

  def down do
    execute "DELETE FROM loop_steps WHERE role IN ('hook', 'planning')"

    execute "ALTER TABLE loop_steps DROP CONSTRAINT loop_steps_role_check"

    execute "ALTER TABLE loop_steps ADD CONSTRAINT loop_steps_role_check CHECK (role IN ('maker', 'checker'))"

    execute "DELETE FROM loops WHERE role = 'planning'"

    execute "ALTER TABLE loops DROP CONSTRAINT loops_role_check"
    execute "ALTER TABLE loops ADD CONSTRAINT loops_role_check CHECK (role IN ('task', 'hook'))"
  end
end
