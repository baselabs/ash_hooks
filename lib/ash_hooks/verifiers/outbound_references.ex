defmodule AshHooks.Verifiers.OutboundReferences do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias Spark.Dsl.{Extension, Verifier}
  alias Spark.Error.DslError

  @uuid_storage :uuid

  @impl true
  def verify(dsl_state) do
    verify_subscription(dsl_state)
    verify_outbound_declarations(dsl_state)
    :ok
  end

  defp verify_subscription(dsl_state) do
    case Verifier.get_option(dsl_state, [:subscription], :endpoint_resource, nil) do
      nil ->
        :ok

      endpoint_resource ->
        subscription_resource = Verifier.get_persisted(dsl_state, :module)

        endpoint_key =
          single_uuid_key!(
            endpoint_resource,
            :endpoint,
            subscription_resource,
            [:subscription, :endpoint_resource]
          )

        _subscription_key =
          single_uuid_key!(
            Verifier.get_entities(dsl_state, [:attributes]),
            :subscription,
            subscription_resource,
            [:attributes]
          )

        reference =
          dsl_state
          |> Verifier.get_entities([:attributes])
          |> Enum.find(&(&1.name == :endpoint_id))

        require_compatible_reference!(
          reference,
          endpoint_key,
          :subscription,
          :endpoint_id,
          :endpoint,
          subscription_resource,
          [:subscription, :endpoint_resource]
        )
    end
  end

  defp verify_outbound_declarations(dsl_state) do
    owner = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Verifier.get_entities([:webhooks])
    |> Enum.filter(&is_struct(&1, AshHooks.Outbound))
    |> Enum.each(&verify_outbound_declaration(&1, owner))
  end

  defp verify_outbound_declaration(
         %{subscriptions: subscriptions, deliveries: deliveries} = declaration,
         owner
       ) do
    path = [:webhooks, :outbound, declaration.name]

    if resource?(subscriptions) and resource?(deliveries) do
      endpoint = Extension.get_opt(subscriptions, [:subscription], :endpoint_resource, nil)

      if resource?(endpoint) do
        endpoint_key = single_uuid_key!(endpoint, :endpoint, owner, path)
        subscription_key = single_uuid_key!(subscriptions, :subscription, owner, path)

        require_compatible_reference!(
          ResourceInfo.attribute(subscriptions, :endpoint_id),
          endpoint_key,
          :subscription,
          :endpoint_id,
          :endpoint,
          owner,
          path
        )

        require_compatible_reference!(
          ResourceInfo.attribute(deliveries, :endpoint_id),
          endpoint_key,
          :delivery,
          :endpoint_id,
          :endpoint,
          owner,
          path
        )

        require_compatible_reference!(
          ResourceInfo.attribute(deliveries, :subscription_id),
          subscription_key,
          :delivery,
          :subscription_id,
          :subscription,
          owner,
          path
        )
      end
    end
  end

  defp resource?(resource) when is_atom(resource) do
    Code.ensure_compiled(resource) == {:module, resource} and ResourceInfo.resource?(resource)
  end

  defp single_uuid_key!(resource, role, owner, path) when is_atom(resource) do
    if resource?(resource) do
      keys =
        resource
        |> ResourceInfo.primary_key()
        |> Enum.map(&ResourceInfo.attribute(resource, &1))

      single_uuid_key!(keys, role, owner, path)
    else
      raise key_error(owner, path, role, [])
    end
  end

  defp single_uuid_key!(attributes, role, owner, path) when is_list(attributes) do
    keys = Enum.filter(attributes, & &1.primary_key?)

    case keys do
      [key] ->
        if storage_type(key) == @uuid_storage do
          key
        else
          raise key_error(owner, path, role, keys)
        end

      _ ->
        raise key_error(owner, path, role, keys)
    end
  end

  defp require_compatible_reference!(
         reference,
         key,
         reference_role,
         reference_name,
         key_role,
         owner,
         path
       ) do
    if reference && storage_type(reference) == storage_type(key) do
      :ok
    else
      actual = if reference, do: inspect(storage_type(reference)), else: "missing"

      raise DslError,
        module: owner,
        path: path,
        message:
          "#{reference_role} reference #{inspect(reference_name)} has storage type #{actual}; " <>
            "it must match the #{key_role} primary key #{inspect(key.name)} storage type " <>
            "#{inspect(storage_type(key))}. Redeclare #{inspect(reference_name)} with a " <>
            "compatible Ash type or restore the injected UUID reference."
    end
  end

  defp key_error(owner, path, role, keys) do
    descriptions = Enum.map(keys, &{&1.name, storage_type(&1)})

    DslError.exception(
      module: owner,
      path: path,
      message:
        "#{role} resource must declare exactly one UUID-storage-compatible primary key " <>
          "because outbound reference fields store one UUID scalar; found #{inspect(descriptions)}. " <>
          "Use one :uuid or :uuid_v7 primary key under any name. Composite and non-UUID keys " <>
          "cannot be represented by the outbound reference columns."
    )
  end

  defp storage_type(attribute),
    do: Ash.Type.storage_type(attribute.type, attribute.constraints)
end
