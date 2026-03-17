defmodule Algedonia.Repo.Migrations.AddLandModeToTickets do
  use Ecto.Migration

  def change do
    alter table(:tickets) do
      add :land_mode, :string
    end

    create constraint(:tickets, :tickets_land_mode_check,
             check: "land_mode IN ('auto_land', 'review_gate') OR land_mode IS NULL"
           )
  end
end
