defmodule Algedonia.Loops.Loop do
  @moduledoc """
  Schema for a loop — a single maker-checker unit of work for a ticket.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Algedonia.Daemons.DaemonRegistration
  alias Algedonia.Loops.LoopStep
  alias Algedonia.Tickets.Ticket
  alias Algedonia.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :running, :passed, :failed]

  @roles [:task, :hook, :planning, :review]

  schema "loops" do
    belongs_to :workspace, Algedonia.Workspaces.Workspace
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :role, Ecto.Enum, values: @roles, default: :task
    field :manual_gate, :boolean, default: false
    field :current_attempt, :integer, default: 0
    field :max_attempts, :integer, default: 10
    field :rubric, :string
    field :branch_name, :string
    field :checker_config, :map
    field :land_mode, :string
    field :pr_url, :string

    belongs_to :ticket, Algedonia.Tickets.Ticket
    belongs_to :assigned_daemon, Algedonia.Daemons.DaemonRegistration

    has_many :steps, Algedonia.Loops.LoopStep

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Algedonia.Types.id(),
          workspace_id: Algedonia.Types.id(),
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          title: String.t(),
          description: String.t() | nil,
          status: :pending | :running | :passed | :failed,
          role: :task | :hook | :planning | :review,
          manual_gate: boolean(),
          current_attempt: integer(),
          max_attempts: integer(),
          rubric: String.t() | nil,
          branch_name: String.t() | nil,
          checker_config: map() | nil,
          land_mode: String.t() | nil,
          pr_url: String.t() | nil,
          ticket_id: Algedonia.Types.id(),
          ticket: Ticket.t() | Ecto.Association.NotLoaded.t(),
          assigned_daemon_id: Algedonia.Types.id() | nil,
          assigned_daemon: DaemonRegistration.t() | Ecto.Association.NotLoaded.t() | nil,
          steps: [LoopStep.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

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
      :checker_config,
      :land_mode,
      :pr_url,
      :workspace_id,
      :ticket_id,
      :assigned_daemon_id
    ])
    |> validate_required([:title, :ticket_id, :workspace_id])
    |> validate_inclusion(:role, @roles)
    |> check_constraint(:role, name: :loops_role_check)
  end
end
