defmodule Algedonia.Repo.Migrations.MakeTicketNumberUniquePerWorkspace do
  use Ecto.Migration

  def change do
    drop index(:tickets, [:number])
    create unique_index(:tickets, [:workspace_id, :number])
  end
end
