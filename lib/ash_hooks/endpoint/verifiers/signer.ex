defmodule AshHooks.Endpoint.Verifiers.Signer do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.{Extension, Verifier}
  alias Spark.Error.DslError

  def verify(state) do
    signer = Extension.get_opt(state, [:endpoint], :signer)
    attributes = Extension.get_opt(state, [:endpoint], :signer_attributes, [])

    cond do
      is_nil(signer) and
          Extension.get_opt(state, [:endpoint], :native_signing, :required) == :optional ->
        error(state, "native_signing :optional requires signer")

      not is_nil(signer) and not signer?(signer) ->
        error(state, "signer must implement AshHooks.Signer")

      true ->
        Enum.reduce_while(attributes, :ok, fn name, :ok ->
          case verify_attribute(state, name) do
            :ok -> {:cont, :ok}
            failure -> {:halt, failure}
          end
        end)
    end
  end

  defp signer?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :sign, 2) and
      AshHooks.Signer in
        (module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten())
  end

  defp verify_attribute(state, name) do
    attribute = Enum.find(Verifier.get_entities(state, [:attributes]), &(&1.name == name))

    cond do
      is_nil(attribute) ->
        error(state, "signer_attributes must name resource attributes")

      attribute.sensitive? ->
        error(state, "signer_attributes must not be sensitive; store references only")

      not comparable?(attribute) ->
        error(state, "signer_attributes require a JSON-readable stored type with Ash.Type equality")

      true ->
        :ok
    end
  end

  defp comparable?(attribute) do
    storage = Ash.Type.storage_type(attribute.type, attribute.constraints)

    with true <- json_storage?(storage),
         {:ok, stored} <- Ash.Type.dump_to_embedded(attribute.type, nil, attribute.constraints),
         {:ok, cast} <- Ash.Type.cast_input(attribute.type, stored, attribute.constraints),
         {:ok, value} <- Ash.Type.apply_constraints(attribute.type, cast, attribute.constraints) do
      Ash.Type.equal?(attribute.type, nil, value, attribute.constraints)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp json_storage?({:array, type}), do: json_storage?(type)

  defp json_storage?(type),
    do:
      type in [
        :string, :text, :integer, :float, :boolean, :map, :uuid, :binary_id,
        :date, :time, :time_usec, :naive_datetime, :naive_datetime_usec,
        :utc_datetime, :utc_datetime_usec, :decimal
      ]

  defp error(state, message) do
    {:error,
     DslError.exception(
       module: Verifier.get_persisted(state, :module),
       path: [:endpoint, :signer],
       message: message
     )}
  end
end
