defmodule Algedonia.Tickets.Ticket do
  @moduledoc """
  Schema for a ticket — the primary unit of work in Algedonia.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Algedonia.Agents
  alias Algedonia.Tickets.Comment
  alias Algedonia.Workspaces.Workspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tickets" do
    belongs_to :workspace, Algedonia.Workspaces.Workspace
    field :title, :string
    field :description, :string
    field :number, :integer

    field :status, Ecto.Enum,
      values: [:backlog, :planning, :halted, :in_progress, :in_review, :completed, :archived],
      default: :backlog

    field :type, Ecto.Enum, values: [:feature, :bug, :chore, :spike]
    field :coding_agent, Ecto.Enum, values: [:codex, :claude_code]
    field :priority, :integer, default: 3
    field :assignee, :string
    field :acceptance_criteria, :string
    field :rubric, :string
    field :overview, :string
    field :land_mode, Ecto.Enum, values: [:review_gate, :auto_land]
    field :blocked_by, {:array, :binary_id}, default: []
    field :review_pr_number, :integer

    has_many :comments, Algedonia.Tickets.Comment

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Algedonia.Types.id(),
          workspace_id: Algedonia.Types.id(),
          workspace: Workspace.t() | Ecto.Association.NotLoaded.t(),
          title: String.t(),
          description: String.t() | nil,
          number: integer() | nil,
          status:
            :backlog | :planning | :halted | :in_progress | :in_review | :completed | :archived,
          type: :feature | :bug | :chore | :spike,
          coding_agent: :codex | :claude_code,
          priority: integer(),
          assignee: String.t() | nil,
          acceptance_criteria: String.t() | nil,
          rubric: String.t() | nil,
          overview: String.t() | nil,
          land_mode: :review_gate | :auto_land | nil,
          blocked_by: [Algedonia.Types.id()],
          review_pr_number: integer() | nil,
          comments: [Comment.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Returns a changeset for creating or updating a ticket.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :workspace_id,
      :number,
      :title,
      :description,
      :status,
      :type,
      :coding_agent,
      :priority,
      :assignee,
      :acceptance_criteria,
      :rubric,
      :overview,
      :land_mode,
      :blocked_by,
      :review_pr_number
    ])
    |> maybe_put_default_coding_agent()
    |> validate_required([:workspace_id, :title, :type, :priority])
    |> validate_inclusion(:priority, 1..5)
    |> validate_blocked_by()
    |> unique_constraint([:workspace_id, :number])
  end

  defp validate_blocked_by(changeset) do
    blocked_by = get_field(changeset, :blocked_by) || []

    if Enum.uniq(blocked_by) == blocked_by do
      changeset
    else
      add_error(changeset, :blocked_by, "contains duplicate blocker references")
    end
  end

  defp maybe_put_default_coding_agent(changeset) do
    case get_field(changeset, :coding_agent) do
      nil -> put_change(changeset, :coding_agent, Agents.default_coding_agent())
      _ -> changeset
    end
  end
end
