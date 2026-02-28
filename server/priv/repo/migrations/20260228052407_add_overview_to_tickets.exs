defmodule Algedonia.Repo.Migrations.AddOverviewToTickets do
  use Ecto.Migration

  def change do
    alter table(:tickets) do
      add :overview, :text
    end
  end
end
