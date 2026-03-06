defmodule Algedonia.Repo.Migrations.RemovePathPrefixesFromLoops do
  use Ecto.Migration

  def up do
    alter table(:loops) do
      remove :path_prefixes
    end
  end

  def down do
    alter table(:loops) do
      add :path_prefixes, {:array, :text}
    end
  end
end
