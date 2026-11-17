defmodule AshHooks.OutboundOutbox.Verifier do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.{Extension, Verifier}
  alias Spark.Error.DslError

  def verify(state) do
    tenant = Verifier.get_option(state, [:multitenancy], :attribute)
    expected = Enum.reject([tenant, :event_uuid], &is_nil/1) |> Enum.sort()

    identity =
      Enum.find(Verifier.get_entities(state, [:identities]), &(&1.name == :unique_publication))

    metadata = Enum.find(Verifier.get_entities(state, [:attributes]), &(&1.name == :metadata))

    cond do
      invalid_identity?(identity, expected) ->
        error(
          state,
          "unique_publication must contain exactly the tenant attribute and event_uuid, without all_tenants? or where"
        )

      metadata.type != Ash.Type.Map or Keyword.has_key?(metadata.constraints, :fields) ->
        error(
          state,
          "outbox metadata must use the unmodified :map type without a custom codec or fields constraint"
        )

      custom_metadata_codec?(state) ->
        error(state, "outbox metadata storage_types cannot replace the map codec")

      not metadata_storage?(state) ->
        error(
          state,
          "PostgreSQL outbox metadata requires the native :json migration type to preserve numeric kinds"
        )

      option(state, :fanout_timeout) >= option(state, :fanout_lease_seconds) * 1_000 ->
        error(state, "fanout_timeout must be below fanout_lease_seconds")

      option(state, :fanout_base_backoff_seconds) > option(state, :fanout_max_backoff_seconds) ->
        error(state, "fanout_base_backoff_seconds must not exceed fanout_max_backoff_seconds")

      true ->
        verify_routes(state)
    end
  end

  defp invalid_identity?(identity, expected),
    do: identity.all_tenants? || identity.where || Enum.sort(identity.keys) != expected

  defp custom_metadata_codec?(state) do
    path =
      case Verifier.get_persisted(state, :data_layer) do
        AshPostgres.DataLayer -> [:postgres]
        AshSqlite.DataLayer -> [:sqlite]
        _other -> []
      end

    path != [] and
      Keyword.get(Extension.get_opt(state, path, :storage_types, []), :metadata) not in [
        nil,
        :map
      ]
  end

  defp metadata_storage?(state) do
    Verifier.get_persisted(state, :data_layer) != AshPostgres.DataLayer or
      Keyword.get(Extension.get_opt(state, [:postgres], :migration_types, []), :metadata) == :json
  end

  defp verify_routes(state) do
    routes = option(state, :delivery_routes)

    if routes == [] or length(Keyword.keys(routes)) != length(Enum.uniq(Keyword.keys(routes))) do
      error(state, "delivery_routes must have distinct names and at least one route")
    else
      Enum.each(routes, fn {_name, callback} ->
        verify_delivery_callback!(state, callback)
      end)

      if not callback?(option(state, :trigger), 2),
        do: raise_error(state, "trigger must be an exported two-argument callback")

      :ok
    end
  end

  defp verify_delivery_callback!(state, callback) do
    if not callback?(callback, 2),
      do: raise_error(state, "delivery routes must be exported two-argument callbacks or nil")
  end

  defp callback?(nil, _arity), do: true

  defp callback?({module, function}, arity) when is_atom(module) and is_atom(function),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp callback?(_callback, _arity), do: false

  defp option(state, key), do: Extension.get_opt(state, [:outbox], key)
  defp error(state, message), do: {:error, exception(state, message)}
  defp raise_error(state, message), do: raise(exception(state, message))

  defp exception(state, message),
    do:
      DslError.exception(
        module: Verifier.get_persisted(state, :module),
        path: [:outbox],
        message: message
      )
end
