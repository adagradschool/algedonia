defmodule Algedonia.Daemons.DaemonRegistration do
  @moduledoc """
  Schema for daemon registration records.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "daemon_registrations" do
    field :name, :string
    field :display_name, :string
    field :status, Ecto.Enum, values: [:online, :unhealthy, :offline], default: :offline
    field :capacity, :integer, default: 3
    field :running_loops, :integer, default: 0
    field :last_heartbeat_at, :utc_datetime_usec
    field :connected_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(daemon, attrs) do
    daemon
    |> cast(attrs, [
      :name,
      :display_name,
      :status,
      :capacity,
      :running_loops,
      :last_heartbeat_at,
      :connected_at
    ])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
