defmodule Algedonia.Loops.Loop do
  @moduledoc """
  Schema for a loop — a single maker-checker unit of work within a DAG.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [
    :pending,
    :ready,
    :assigned,
    :running_maker,
    :running_checker,
    :passed,
    :failed,
    :escalated,
    :needs_clarification,
    :pending_approval,
    :skipped,
    :resolved
  ]

  @roles [:task, :decompose, :decompose_checker, :hook]

  schema "loops" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :role, Ecto.Enum, values: @roles, default: :task
    field :manual_gate, :boolean, default: false
    field :current_attempt, :integer, default: 0
    field :max_attempts, :integer, default: 10
    field :rubric, :string
    field :branch_name, :string

    belongs_to :dag, Algedonia.Dags.Dag
    belongs_to :ticket, Algedonia.Tickets.Ticket
    belongs_to :assigned_daemon, Algedonia.Daemons.DaemonRegistration

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(loop, attrs) do
    loop
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :role,
      :manual_gate,
      :current_attempt,
      :max_attempts,
      :rubric,
      :branch_name,
      :dag_id,
      :ticket_id,
      :assigned_daemon_id
    ])
    |> validate_required([:title, :dag_id])
  end
end
