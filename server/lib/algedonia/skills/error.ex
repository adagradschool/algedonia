defmodule Algedonia.Skills.Error do
  @moduledoc """
  Stable, typed error payload used by skill parsing and checker config validation.
  """

  @enforce_keys [:code, :message]
  defstruct [:file, :field, :path, :index, :code, :message]

  @type t :: %__MODULE__{
          file: String.t() | nil,
          field: String.t() | nil,
          path: String.t() | nil,
          index: non_neg_integer() | nil,
          code: String.t(),
          message: String.t()
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      file: error.file,
      field: error.field,
      path: error.path,
      index: error.index,
      code: error.code,
      message: error.message
    }
  end
end
