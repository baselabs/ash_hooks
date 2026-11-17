defmodule AshHooks.OutboundOutbox.Verifier do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.{Extension, Verifier}

  def verify(state) do
    tenant = Verifier.get_option(state, [:multitenancy], :attribute)
    expected = Enum.reject([tenant, :event_uuid], &is_nil/1) |> Enum.sort()
    identity = Enum.find(Verifier.get_entities(state, [:identities]), &(&1.name == :unique_publication))
    metadata = Enum.find(Verifier.get_entities(state, [:attributes]), &(&1.name == :metadata))

    cond do
      identity.all_tenants? or identity.where or Enum.sort(identity.keys) != expected ->
        error(state, "unique_publication must contain exactly the tenant attribute and event_uuid, without all_tenants? or where")

      metadata.type != Ash.Type.Map or Keyword.has_key?(metadata.constraints, :fields) ->
        error(state, "outbox metadata must use the unmodified :map type without a custom codec or fields constraint")

      option(state, :fanout_timeout) >= option(state, :fanout_lease_seconds) * 1_000 ->
        error(state, "fanout_timeout must be below fanout_lease_seconds")

      option(state, :fanout_base_backoff_seconds) > option(state, :fanout_max_backoff_seconds) ->
        error(state, "fanout_base_backoff_seconds must not exceed fanout_max_backoff_seconds")

      true ->
        verify_routes(state)
    end
  end

  defp verify_routes(state) do
    routes = option(state, :delivery_routes)

    if routes == [] or length(Keyword.keys(routes)) != length(Enum.uniq(Keyword.keys(routes))) do
      error(state, "delivery_routes must have distinct names and at least one route")
    else
      Enum.each(routes, fn {_name, callback} ->
        if not callback?(callback, 2), do: raise_error(state, "delivery routes must be exported two-argument callbacks or nil")
      end)

      if not callback?(option(state, :trigger), 2), do: raise_error(state, "trigger must be an exported two-argument callback")
      :ok
    end
  end

  defp callback?(nil, _arity), do: true
  defp callback?({module, function}, arity) when is_atom(module) and is_atom(function),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  defp callback?(_callback, _arity), do: false

  defp option(state, key), do: Extension.get_opt(state, [:outbox], key)
  defp error(state, message), do: {:error, exception(state, message)}
  defp raise_error(state, message), do: raise(exception(state, message))
  defp exception(state, message),
    do: Spark.Error.DslError.exception(module: Verifier.get_persisted(state, :module), path: [:outbox], message: message)
end
