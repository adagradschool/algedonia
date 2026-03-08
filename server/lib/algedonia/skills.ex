defmodule Algedonia.Skills do
  @moduledoc """
  Shared skill registry and checker-config validation boundary.
  """

  alias Algedonia.Skills.{Catalog, CheckerConfigValidator, Error, Registry, Skill}

  @type checker_invocation :: CheckerConfigValidator.invocation()
  @type catalog_payload :: Catalog.t()

  @spec load_registry(keyword()) :: Registry.t()
  def load_registry(opts \\ []), do: Registry.load(opts)

  @spec list_skills(keyword()) :: [Skill.t()]
  def list_skills(opts \\ []) do
    opts
    |> load_registry()
    |> Registry.list()
  end

  @spec catalog(keyword()) :: catalog_payload()
  def catalog(opts \\ []), do: Catalog.load(opts)

  @spec validate_checker_config(term(), keyword()) ::
          {:ok, [checker_invocation()], Registry.t()} | {:error, [Error.t()], Registry.t()}
  def validate_checker_config(config, opts \\ []) do
    registry = load_registry(opts)

    case CheckerConfigValidator.validate(config, registry) do
      {:ok, invocations} -> {:ok, invocations, registry}
      {:error, errors} -> {:error, errors, registry}
    end
  end

  @spec errors_to_maps([Error.t()]) :: [map()]
  def errors_to_maps(errors) when is_list(errors), do: Enum.map(errors, &Error.to_map/1)
end
