defmodule Algedonia.Repo.Migrations.AddCodingAgentToTickets do
  use Ecto.Migration

  def change do
    alter table(:tickets) do
      add :coding_agent, :text, null: false, default: "claude_code"
    end

    create constraint(:tickets, :valid_coding_agent,
             check: "coding_agent IN ('codex', 'claude_code')"
           )
  end
end
