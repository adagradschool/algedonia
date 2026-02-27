defmodule Algedonia.Repo.Migrations.AddMaxAttemptsToTickets do
  use Ecto.Migration

  def change do
    alter table(:tickets) do
      add :max_attempts, :integer, default: 10
    end
  end
end
