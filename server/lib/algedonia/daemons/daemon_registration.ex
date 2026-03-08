defmodule Algedonia.Daemons.DaemonRegistration do
  @moduledoc """
  Schema for daemon registration records.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Algedonia.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "daemon_registrations" do
    field :name, :string
    field :display_name, :string
    field :status, Ecto.Enum, values: [:online, :unhealthy, :offline], default: :offline
    field :capacity, :integer, default: 3
    field :running_loops, :integer, default: 0
    field :available_agents, {:array, :string}, default: []
    field :bare_repos, {:array, :string}, default: []
    field :terminal_ws_url, :string
    field :last_heartbeat_at, :utc_datetime_usec
    field :connected_at, :utc_datetime_usec

    belongs_to :user, Algedonia.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Algedonia.Types.id(),
          name: String.t(),
          display_name: String.t() | nil,
          status: :online | :unhealthy | :offline,
          capacity: integer(),
          running_loops: integer(),
          available_agents: [String.t()],
          bare_repos: [String.t()],
          terminal_ws_url: String.t() | nil,
          last_heartbeat_at: DateTime.t() | nil,
          connected_at: DateTime.t() | nil,
          user_id: Algedonia.Types.id(),
          user: User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def changeset(daemon, attrs) do
    daemon
    |> cast(attrs, [
      :name,
      :display_name,
      :status,
      :capacity,
      :running_loops,
      :available_agents,
      :bare_repos,
      :terminal_ws_url,
      :last_heartbeat_at,
      :connected_at,
      :user_id
    ])
    |> validate_required([:name, :user_id])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:name)
  end
end
