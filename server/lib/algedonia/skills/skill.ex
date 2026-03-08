defmodule Algedonia.Skills.Skill do
  @moduledoc false

  @enforce_keys [:name, :description, :file]
  defstruct [:name, :description, :file, :params_schema, :metadata]

  @type params_schema ::
          %{optional(String.t()) => term()}
          | String.t()
          | nil

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          file: String.t(),
          params_schema: params_schema(),
          metadata: map()
        }
end
