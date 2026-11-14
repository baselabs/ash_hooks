defmodule AshHooks.Endpoint.Keys do
  @moduledoc false
  alias Ash.Resource.Info
  alias AshHooks.{KeyIssuing, KeyLifecycle, Phase, PrimaryKey, Tenancy}
  alias AshHooks.KeyRegistry.{Storage, Transitions}
  alias Spark.Dsl.Extension

  def roll(%resource{} = owner, opts) do
    slot = Keyword.get(opts, :slot, :standard)

    with :ok <- Phase.outside_transaction(resource),
         :ok <- require_custody(resource),
         :ok <- KeyLifecycle.validate_roll(resource, opts),
         {:ok, spec, disclosure} <- input(opts, slot) do
      result =
        KeyIssuing.run(resource, [spec], opts, fn [issued] ->
          KeyLifecycle.roll_reference(
            owner,
            opts
            |> Keyword.put(:new_secret_ref, issued.ref)
            |> Keyword.put(:new_secret_kind, issued.kind)
          )
        end)

      disclose(result, disclosure)
    end
  end

  def reissue(%resource{} = owner, opts) do
    slot = Keyword.get(opts, :slot, :standard)
    fields = KeyLifecycle.fields(slot)

    with :ok <- Phase.outside_transaction(resource),
         :ok <- require_custody(resource),
         {:ok, kind} <- current_kind(owner, fields),
         {:ok, spec, disclosure} <- generate(kind, slot) do
      opts = Keyword.put(opts, :retire, [Map.fetch!(owner, fields.ref)])

      result =
        KeyIssuing.run(resource, [spec], opts, fn issued ->
          values =
            issued
            |> KeyIssuing.attributes()
            |> Map.put(fields.created_at, Transitions.now(opts))
            |> Map.put(fields.first_used_at, nil)

          replace(owner, [{fields.ref, Map.fetch!(owner, fields.ref)}], values, opts[:tenant])
        end)

      disclose(result, disclosure)
    end
  end

  defp current_kind(owner, fields) do
    case Map.get(owner, fields.kind) do
      nil -> {:error, :byte_slot}
      kind -> {:ok, kind}
    end
  end

  def adopt(%resource{} = owner, opts) do
    with :ok <- Phase.outside_transaction(resource),
         :ok <- require_custody(resource),
         {:ok, tenant} <- Tenancy.resolve([resource, Storage.registry(resource)], opts[:tenant]),
         :ok <- dated_previous(owner),
         {:ok, specs} <- adoption_specs(owner, opts) do
      adopt_specs(owner, specs, Keyword.put(opts, :tenant, tenant))
    end
  end

  defp adopt_specs(owner, [], opts) do
    Phase.run(
      owner.__struct__
      |> Storage.owner_query(opts[:tenant])
      |> Ash.Query.do_filter(PrimaryKey.filter(owner)),
      opts[:tenant],
      fn query ->
        case Ash.read_one(query, tenant: opts[:tenant], authorize?: false) do
          {:ok, nil} -> {:error, :rolled_underneath}
          result -> result
        end
      end
    )
  end

  defp adopt_specs(owner, specs, opts) do
    fence =
      Enum.flat_map(specs, fn spec ->
        [{spec.field, Map.fetch!(owner, spec.field)}, {spec.kind_field, [is_nil: true]}]
      end)

    KeyIssuing.run(owner.__struct__, specs, opts, fn issued ->
      replace(owner, fence, KeyIssuing.attributes(issued), opts[:tenant])
    end)
  end

  defp dated_previous(owner) do
    undated? =
      Enum.any?([:standard, :legacy], fn slot ->
        fields = KeyLifecycle.fields(slot)
        Map.get(owner, fields.previous_ref) && is_nil(Map.get(owner, fields.retired_at))
      end)

    if undated?, do: {:error, :previous_secret_undated}, else: :ok
  end

  defp adoption_specs(owner, opts) do
    owner.__struct__
    |> Transitions.slots()
    |> Enum.filter(fn {field, kind_field} ->
      Map.get(owner, field) && is_nil(Map.get(owner, kind_field))
    end)
    |> Enum.reduce_while({:ok, []}, fn {field, kind_field}, {:ok, specs} ->
      slot = if field in [:secret_ref, :previous_secret_ref], do: :standard, else: :legacy

      with {:ok, material} <- resolve_byte(owner, Map.fetch!(owner, field), opts),
           {:ok, spec, nil} <- decode(material, slot) do
        {:cont, {:ok, specs ++ [%{spec | field: field, kind_field: kind_field}]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_byte(owner, ref, opts) do
    case Extension.get_opt(owner.__struct__, [:endpoint], :secret_resolver) do
      nil ->
        {:error, :secret_resolver_required}

      {module, function} ->
        args = if opts[:tenant_aware_secrets], do: [ref, opts[:tenant]], else: [ref]

        case apply(module, function, args) do
          {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
          _ -> AshHooks.Errors.from_custody_result(:invalid_resolver_result)
        end
    end
  end

  defp replace(owner, fence, values, tenant) do
    result =
      owner.__struct__
      |> Storage.owner_query(tenant)
      |> Ash.Query.do_filter(PrimaryKey.filter(owner))
      |> Ash.Query.do_filter(fence)
      |> Ash.bulk_update(:set_custody_keys, values,
        authorize?: false,
        tenant: tenant,
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, records: [row]} -> {:ok, row}
      %Ash.BulkResult{status: :success, records: []} -> {:error, :rolled_underneath}
      %Ash.BulkResult{errors: [error | _]} -> {:error, error}
    end
  end

  def create(resource, attrs, opts) do
    with :ok <- Phase.outside_transaction(resource),
         :ok <- require_custody(resource),
         {:ok, spec, disclosure} <- input(opts, :standard) do
      result =
        KeyIssuing.run(resource, [spec], opts, fn issued ->
          create_owner(resource, attrs, issued, opts)
        end)

      disclose(result, disclosure)
    end
  end

  defp create_owner(resource, attrs, issued, opts) do
    action = Keyword.get(opts, :action, Info.primary_action!(resource, :create).name)

    attributes =
      issued
      |> KeyIssuing.attributes()
      |> Map.put(:secret_created_at, Transitions.now(opts))
      |> Map.put(:secret_first_used_at, nil)
      |> tenant_attributes(resource, opts[:tenant])

    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(
      Map.merge(Storage.context(resource), %{ash_hooks_issued_attributes: attributes})
    )
    |> Ash.Changeset.for_create(action, attrs, tenant: opts[:tenant])
    |> Ash.create(authorize?: false)
  end

  defp tenant_attributes(attributes, resource, tenant) do
    case Info.multitenancy_attribute(resource) do
      nil ->
        attributes

      field ->
        {module, function, args} = Info.multitenancy_parse_attribute(resource)
        value = apply(module, function, [Ash.ToTenant.to_tenant(tenant, resource) | args])
        Map.put(attributes, field, value)
    end
  end

  defp input(opts, slot) do
    case Enum.filter([:generate, :material, :new_secret_ref], &Keyword.has_key?(opts, &1)) do
      [:generate] -> generate(opts[:generate], slot)
      [:material] -> decode(opts[:material], slot)
      _ -> {:error, :key_input_required}
    end
  end

  defp generate(kind, slot) do
    if allowed?(kind, slot) do
      material = :crypto.strong_rand_bytes(32)
      {:ok, spec(slot, kind, material), disclosure(kind, material)}
    else
      {:error, :kind_not_allowed}
    end
  end

  defp allowed?({:standard_webhooks, version}, :standard), do: version in [:v1, :v1a]
  defp allowed?({:legacy_hmac, :sha256}, :legacy), do: true
  defp allowed?(_kind, _slot), do: false

  defp decode(material, :legacy) when is_binary(material) and material != "",
    do: {:ok, spec(:legacy, {:legacy_hmac, :sha256}, material), nil}

  defp decode("whsk_" <> encoded, :standard),
    do: decode_spec(encoded, {:standard_webhooks, :v1a})

  defp decode("whsec_" <> encoded, :standard),
    do: decode_spec(encoded, {:standard_webhooks, :v1})

  defp decode(encoded, :standard) when is_binary(encoded),
    do: decode_spec(encoded, {:standard_webhooks, :v1})

  defp decode(_material, _slot), do: {:error, :invalid_material}

  defp decode_spec(encoded, kind) do
    result =
      case Base.decode64(encoded) do
        :error -> Base.decode64(encoded, padding: false)
        result -> result
      end

    case result do
      {:ok, material} -> {:ok, spec(:standard, kind, material), nil}
      :error -> {:error, :invalid_material}
    end
  end

  defp spec(slot, kind, material) do
    fields = KeyLifecycle.fields(slot)
    %{field: fields.ref, kind_field: fields.kind, kind: kind, material: material}
  end

  defp disclosure({:standard_webhooks, :v1}, material),
    do: "whsec_" <> Base.encode64(material)

  defp disclosure({:standard_webhooks, :v1a}, material) do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, material)
    "whpk_" <> Base.encode64(public)
  end

  defp disclosure({:legacy_hmac, :sha256}, material), do: material

  defp disclose({:ok, row}, nil), do: {:ok, row}
  defp disclose({:ok, row}, disclosure), do: {:ok, row, disclosure}
  defp disclose(error, _disclosure), do: error

  defp require_custody(resource) do
    if Storage.custodian(resource), do: :ok, else: {:error, :custody_required}
  end
end
