defmodule Algedonia.Repo.Migrations.AddCheckerReceiptFieldsToLoopSteps do
  use Ecto.Migration

  def change do
    alter table(:loop_steps) do
      add :step_id, :text
      add :skill, :text
      add :order_index, :integer
      add :required, :boolean, default: true, null: false
      add :summary, :text
    end

    create index(:loop_steps, [:loop_id, :attempt, :order_index],
             name: :idx_loop_steps_loop_id_attempt_order
           )
  end
end
