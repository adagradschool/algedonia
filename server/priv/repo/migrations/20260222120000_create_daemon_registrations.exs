defmodule Algedonia.Repo.Migrations.CreateDaemonRegistrations do
  use Ecto.Migration

  def change do
    create table(:daemon_registrations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :display_name, :text
      add :status, :text, default: "offline", null: false
      add :capacity, :integer, default: 3, null: false
      add :running_loops, :integer, default: 0, null: false
      add :last_heartbeat_at, :utc_datetime_usec
      add :connected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:daemon_registrations, [:name])
    create index(:daemon_registrations, [:status])

    create constraint(:daemon_registrations, :valid_status,
             check: "status IN ('online', 'unhealthy', 'offline')"
           )
  end
end
