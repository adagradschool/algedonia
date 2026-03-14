defmodule Algedonia.Repo.Migrations.AddWorktreeBootstrapScriptToWorkspaces do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :worktree_bootstrap_script, :text
    end
  end
end
