defmodule Algedonia.Loops.LoopDependency do
  @moduledoc """
  Schema for loop dependencies — edges in the DAG between loops.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "loop_dependencies" do
    belongs_to :upstream_loop, Algedonia.Loops.Loop
    belongs_to :downstream_loop, Algedonia.Loops.Loop
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(dep, attrs) do
    dep
    |> cast(attrs, [:upstream_loop_id, :downstream_loop_id])
    |> validate_required([:upstream_loop_id, :downstream_loop_id])
    |> unique_constraint([:upstream_loop_id, :downstream_loop_id])
  end
end
