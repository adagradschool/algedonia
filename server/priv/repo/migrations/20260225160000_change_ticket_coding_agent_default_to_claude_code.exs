defmodule Algedonia.Repo.Migrations.ChangeTicketCodingAgentDefaultToClaudeCode do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE tickets ALTER COLUMN coding_agent SET DEFAULT 'claude_code'")
  end

  def down do
    execute("ALTER TABLE tickets ALTER COLUMN coding_agent SET DEFAULT 'codex'")
  end
end
