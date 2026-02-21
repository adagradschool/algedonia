defmodule Algedonia.Repo.Migrations.CreateTickets do
  use Ecto.Migration

  def change do
    create table(:tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "backlog"
      add :type, :text, null: false
      add :priority, :integer, null: false, default: 3
      add :assignee, :text
      add :acceptance_criteria, :text
      add :rubric, :text

      timestamps(type: :utc_datetime)
    end

    create index(:tickets, [:status])
    create index(:tickets, [:priority])
    create index(:tickets, [:assignee])

    create constraint(:tickets, :valid_status,
             check:
               "status IN ('backlog', 'decomposing', 'decomposition_failed', 'in_progress', 'completed', 'archived')"
           )

    create constraint(:tickets, :valid_type,
             check: "type IN ('feature', 'bug', 'chore', 'spike')"
           )

    create constraint(:tickets, :valid_priority, check: "priority >= 1 AND priority <= 5")
  end
end
