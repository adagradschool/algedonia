defmodule Algedonia.Skills.CheckerConfigValidator do
  @moduledoc false

  alias Algedonia.Skills.{Error, Registry}

  @type invocation :: %{skill: String.t(), params: term() | nil}

  @spec validate(term(), Registry.t()) :: {:ok, [invocation()]} | {:error, [Error.t()]}
  def validate(nil, %Registry{}), do: {:ok, []}

  def validate(config, %Registry{} = registry) when is_list(config) do
    validate_steps(config, registry, "$")
  end

  def validate(config, %Registry{} = registry) when is_map(config) do
    config = stringify_keys(config)
    unknown_keys = Map.keys(config) -- ["steps"]

    base_errors =
      Enum.map(unknown_keys, fn key ->
        Error.new(%{
          field: key,
          path: "$.#{key}",
          index: nil,
          code: "unknown_checker_config_field",
          message: "checker_config has unknown top-level field #{inspect(key)}"
        })
      end)

    case Map.get(config, "steps") do
      steps when is_list(steps) ->
        case validate_steps(steps, registry, "$.steps") do
          {:ok, invocations} when base_errors == [] -> {:ok, invocations}
          {:ok, _invocations} -> {:error, base_errors}
          {:error, errors} -> {:error, base_errors ++ errors}
        end

      nil ->
        {:error,
         base_errors ++
           [
             Error.new(%{
               field: "steps",
               path: "$.steps",
               index: nil,
               code: "missing_checker_steps",
               message: "checker_config must include a steps list"
             })
           ]}

      value ->
        {:error,
         base_errors ++
           [
             Error.new(%{
               field: "steps",
               path: "$.steps",
               index: nil,
               code: "invalid_checker_steps_type",
               message: "checker_config.steps must be a list, got: #{inspect(value)}"
             })
           ]}
    end
  end

  def validate(_config, %Registry{}) do
    {:error,
     [
       Error.new(%{
         field: "checker_config",
         path: "$",
         index: nil,
         code: "invalid_checker_config_type",
         message:
           "checker_config must be either a list of invocations or an object with a steps list"
       })
     ]}
  end

  defp validate_steps(config, registry, base_path) do
    {invocations, errors} =
      config
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {entry, index}, {invocations, errors} ->
        case validate_entry(entry, index, registry, base_path) do
          {:ok, invocation} -> {[invocation | invocations], errors}
          {:error, entry_errors} -> {invocations, errors ++ entry_errors}
        end
      end)

    if errors == [] do
      {:ok, Enum.reverse(invocations)}
    else
      {:error, errors}
    end
  end

  defp validate_entry(entry, index, registry, base_path) when is_map(entry) do
    entry = stringify_keys(entry)
    path = "#{base_path}[#{index}]"

    errors =
      []
      |> validate_entry_keys(entry, index, path)
      |> validate_skill_name(entry, index, path, registry)
      |> validate_params(entry, index, path, registry)

    if errors == [] do
      {:ok, %{skill: entry["skill"], params: Map.get(entry, "params")}}
    else
      {:error, errors}
    end
  end

  defp validate_entry(entry, index, _registry, base_path) do
    {:error,
     [
       Error.new(%{
         field: "checker_config",
         path: "#{base_path}[#{index}]",
         index: index,
         code: "invalid_entry_type",
         message:
           "checker_config entry at index #{index} must be an object, got: #{inspect(entry)}"
       })
     ]}
  end

  defp validate_entry_keys(errors, entry, index, path) do
    unknown_keys = Map.keys(entry) -- ["skill", "params"]

    errors ++
      Enum.map(unknown_keys, fn key ->
        Error.new(%{
          field: key,
          path: "#{path}.#{key}",
          index: index,
          code: "unknown_entry_field",
          message: "checker_config entry #{index} has unknown field #{inspect(key)}"
        })
      end)
  end

  defp validate_skill_name(errors, entry, index, path, registry) do
    case parse_skill_name(entry, index, path) do
      {:ok, skill_name} ->
        if Registry.get(registry, skill_name) do
          errors
        else
          errors ++ [unknown_skill_error(skill_name, index, path)]
        end

      {:error, error} ->
        errors ++ [error]
    end
  end

  defp validate_params(errors, entry, index, path, registry) do
    skill_name =
      case Map.get(entry, "skill") do
        skill when is_binary(skill) -> String.trim(skill)
        _ -> nil
      end

    skill = Registry.get(registry, skill_name)

    with skill when not is_nil(skill) <- skill,
         {:ok, schema} <- normalize_schema(skill.params_schema) do
      params = Map.get(entry, "params")
      errors ++ validate_params_by_schema(params, schema, index, "#{path}.params")
    else
      nil ->
        errors

      {:error, message} ->
        errors ++
          [
            Error.new(%{
              file: skill && skill.file,
              field: "params_schema",
              path: "#{path}.params",
              index: index,
              code: "invalid_skill_schema",
              message: message
            })
          ]
    end
  end

  defp validate_params_by_schema(_params, %{"type" => "any"}, _index, _path), do: []

  defp validate_params_by_schema(params, %{"type" => "string"}, index, path) do
    if is_binary(params) do
      []
    else
      [
        Error.new(%{
          field: "params",
          path: path,
          index: index,
          code: "invalid_params_shape",
          message: "checker_config entry #{index} params must be a string"
        })
      ]
    end
  end

  defp validate_params_by_schema(params, %{"type" => type} = schema, index, path)
       when type in ["map", "object"] do
    if is_map(params) do
      required_errors = validate_required_params(params, schema, index, path)
      property_errors = validate_param_properties(params, schema, index, path)
      required_errors ++ property_errors
    else
      [
        Error.new(%{
          field: "params",
          path: path,
          index: index,
          code: "invalid_params_shape",
          message: "checker_config entry #{index} params must be an object"
        })
      ]
    end
  end

  defp validate_params_by_schema(params, %{"type" => type}, index, path)
       when type in ["array", "list"] do
    if is_list(params) do
      []
    else
      [
        Error.new(%{
          field: "params",
          path: path,
          index: index,
          code: "invalid_params_shape",
          message: "checker_config entry #{index} params must be a list"
        })
      ]
    end
  end

  defp validate_params_by_schema(params, %{"type" => "number"}, index, path) do
    if is_number(params) do
      []
    else
      [
        Error.new(%{
          field: "params",
          path: path,
          index: index,
          code: "invalid_params_shape",
          message: "checker_config entry #{index} params must be a number"
        })
      ]
    end
  end

  defp validate_params_by_schema(params, %{"type" => "boolean"}, index, path) do
    if is_boolean(params) do
      []
    else
      [
        Error.new(%{
          field: "params",
          path: path,
          index: index,
          code: "invalid_params_shape",
          message: "checker_config entry #{index} params must be a boolean"
        })
      ]
    end
  end

  defp validate_params_by_schema(_params, %{"type" => type}, index, path) do
    [
      Error.new(%{
        field: "params",
        path: path,
        index: index,
        code: "invalid_skill_schema",
        message: "Unsupported params_schema type #{inspect(type)}"
      })
    ]
  end

  defp validate_required_params(params, schema, index, path) do
    required = Map.get(schema, "required", [])

    required
    |> Enum.reject(&Map.has_key?(params, &1))
    |> Enum.map(fn key ->
      Error.new(%{
        field: key,
        path: "#{path}.#{key}",
        index: index,
        code: "missing_required_param",
        message: "checker_config entry #{index} is missing required param #{inspect(key)}"
      })
    end)
  end

  defp validate_param_properties(params, schema, index, path) do
    Map.get(schema, "properties", %{})
    |> Enum.flat_map(fn {field, schema} ->
      if Map.has_key?(params, field) do
        validate_params_by_schema(Map.get(params, field), schema, index, "#{path}.#{field}")
      else
        []
      end
    end)
  end

  defp normalize_schema(nil), do: {:ok, %{"type" => "any"}}

  defp normalize_schema(schema) when is_binary(schema) do
    {:ok, %{"type" => schema}}
  end

  defp normalize_schema(schema) when is_map(schema) do
    schema = stringify_keys(schema)
    type = Map.get(schema, "type", "any")

    case type do
      type when type in ["map", "object"] ->
        required = normalize_required(schema)
        properties = normalize_properties(schema)

        with {:ok, required} <- required,
             {:ok, properties} <- properties do
          {:ok, %{"type" => type, "required" => required, "properties" => properties}}
        end

      _ ->
        {:ok, %{"type" => type}}
    end
  end

  defp normalize_schema(_schema), do: {:error, "params_schema must be a string or object"}

  defp normalize_required(schema) do
    case Map.get(schema, "required", []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "params_schema.required must be a list of strings"}
        end

      _ ->
        {:error, "params_schema.required must be a list of strings"}
    end
  end

  defp normalize_properties(schema) do
    case Map.get(schema, "properties", %{}) do
      props when is_map(props) ->
        props
        |> stringify_keys()
        |> Enum.reduce_while({:ok, %{}}, fn {field, sub_schema}, {:ok, acc} ->
          normalize_property(field, sub_schema, acc)
        end)

      _ ->
        {:error, "params_schema.properties must be an object"}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      value = normalize_value(value)

      {key, value}
    end)
  end

  defp parse_skill_name(entry, index, path) do
    case Map.get(entry, "skill") do
      skill when is_binary(skill) ->
        skill = String.trim(skill)

        if skill == "" do
          {:error, invalid_skill_name_error(index, path, skill)}
        else
          {:ok, skill}
        end

      value ->
        {:error, invalid_skill_name_error(index, path, value)}
    end
  end

  defp unknown_skill_error(skill_name, index, path) do
    Error.new(%{
      field: "skill",
      path: "#{path}.skill",
      index: index,
      code: "unknown_skill",
      message: "Unknown skill #{inspect(skill_name)} at checker_config index #{index}"
    })
  end

  defp invalid_skill_name_error(index, path, value) do
    Error.new(%{
      field: "skill",
      path: "#{path}.skill",
      index: index,
      code: "invalid_skill_name",
      message:
        "checker_config entry #{index} field skill must be a non-empty string, got: #{inspect(value)}"
    })
  end

  defp normalize_property(field, sub_schema, acc) do
    case normalize_schema(sub_schema) do
      {:ok, normalized} ->
        {:cont, {:ok, Map.put(acc, field, normalized)}}

      {:error, reason} ->
        {:halt, {:error, "Invalid schema for property #{field}: #{reason}"}}
    end
  end

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value
end
