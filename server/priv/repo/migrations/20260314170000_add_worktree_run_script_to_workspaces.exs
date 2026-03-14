defmodule Algedonia.Repo.Migrations.AddWorktreeRunScriptToWorkspaces do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :worktree_run_script, :text
    end
  end
end
