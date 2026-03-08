defmodule Algedonia.Repo.Migrations.AddTerminalWsUrlToDaemonRegistrations do
  use Ecto.Migration

  def change do
    alter table(:daemon_registrations) do
      add :terminal_ws_url, :string
    end
  end
end
