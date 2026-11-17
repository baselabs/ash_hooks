defmodule AshHooks.Keys do
  @moduledoc false
  alias Ash.Resource.Info
  alias AshHooks.Custody.PublicKey
  alias AshHooks.{KeyIssuing, KeyLifecycle, Phase, PrimaryKey, Tenancy}
  alias AshHooks.KeyRegistry.{Storage, Transitions}
  alias Spark.Dsl.Extension

  def roll(%resource{} = owner, opts) do
    slot = Keyword.get(opts, :slot, :standard)

    with :ok <- Phase.outside_transaction(resource),
         :ok <- require_custody(resource),
         :ok <- KeyLifecycle.validate_roll(resource, opts),
         {:ok, spec, disclosure} <- input(opts, slot, resource) do
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

  def enable_native(%resource{} = owner, opts) do
    slot = Keyword.get(opts, :slot, :standard)

    with :ok <- optional_native(resource),
         :ok <- require_custody(resource),
         fields = KeyLifecycle.fields(slot),
         nil <- Map.get(owner, fields.ref),
         {:ok, spec, disclosure} <- input(opts, slot, resource) do
      result =
        KeyIssuing.run(resource, [spec], opts, fn issued ->
          values =
            issued
            |> KeyIssuing.attributes()
            |> Map.put(fields.created_at, Transitions.now(opts))
            |> Map.put(fields.first_used_at, nil)

          replace(owner, [{fields.ref, [is_nil: true]}], values, opts[:tenant])
        end)

      disclose(result, disclosure)
    else
      ref when is_binary(ref) -> {:error, :native_key_exists}
      error -> error
    end
  end

  def disable_native(%resource{} = owner, opts) do
    with :ok <- optional_native(resource),
         :ok <- require_custody(resource),
         :ok <- Phase.outside_transaction(resource),
         {:ok, tenant} <- Tenancy.resolve([resource, Storage.registry(resource)], opts[:tenant]) do
      disable_native_in_tenant(owner, opts, tenant)
    end
  end

  defp disable_native_in_tenant(%resource{} = owner, opts, tenant) do
    slots = [:secret_ref, :previous_secret_ref, :legacy_secret_ref, :legacy_previous_secret_ref]

    fence =
      Enum.map(slots, fn field ->
        {field,
         if(is_nil(Map.get(owner, field)), do: [is_nil: true], else: Map.get(owner, field))}
      end)

    values =
      Map.new(Transitions.slots(resource), fn {ref, _kind} -> {ref, nil} end)
      |> Map.merge(Map.new(Transitions.slots(resource), fn {_ref, kind} -> {kind, nil} end))
      |> Map.merge(Map.new(slots, &{&1, nil}))

    Storage.phase(Storage.registry(resource), resource, tenant, fn ->
      with {:ok, updated} <- replace(owner, fence, values, tenant),
           :ok <- retire_native(owner, Keyword.put(opts, :tenant, tenant)) do
        {:ok, updated}
      end
    end)
  end

  defp retire_native(owner, opts) do
    Enum.reduce_while(Transitions.slots(owner.__struct__), :ok, fn {field, kind}, :ok ->
      case retire_native_slot(owner, field, kind, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp retire_native_slot(owner, field, kind, opts) do
    if Map.get(owner, kind) && Map.get(owner, field) do
      Transitions.retire(owner.__struct__, Map.get(owner, field), Transitions.now(opts), opts)
    else
      :ok
    end
  end

  defp optional_native(resource) do
    if Extension.get_opt(resource, [:endpoint], :native_signing, :required) == :optional,
      do: :ok,
      else: {:error, :native_signing_required}
  end

  def reissue(%resource{} = owner, opts) do
    slot = Keyword.get(opts, :slot, :standard)
    fields = KeyLifecycle.fields(slot)

    with :ok <- Phase.outside_transaction(resource),
         :ok <- require_custody(resource),
         {:ok, kind} <- current_kind(owner, fields),
         {:ok, spec, disclosure} <- generate(kind, slot, resource) do
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
        return_errors?: true,
        context: %{ash_hooks_issued_attributes: values}
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
         {:ok, tenant} <- Tenancy.resolve([resource, Storage.registry(resource)], opts[:tenant]),
         {:ok, specs, disclosure} <- create_specs(resource, opts) do
      opts = Keyword.put(opts, :tenant, tenant)

      result = create_with_specs(resource, attrs, specs, opts)

      disclose(result, disclosure)
    end
  end

  defp create_with_specs(resource, attrs, [], opts),
    do: Phase.run(resource, opts[:tenant], fn -> create_owner(resource, attrs, [], opts) end)

  defp create_with_specs(resource, attrs, specs, opts),
    do:
      KeyIssuing.run(resource, specs, opts, fn issued ->
        create_owner(resource, attrs, issued, opts)
      end)

  defp create_specs(resource, opts) do
    if Storage.section(resource) == :inbound_source do
      with {:ok, specs, disclosure} <- source_current(opts),
           {:ok, previous} <- source_previous(opts, specs) do
        {:ok, specs ++ previous, disclosure}
      end
    else
      with {:ok, spec, disclosure} <- input(opts, :standard, resource),
           do: {:ok, [spec], disclosure}
    end
  end

  defp source_current(opts) do
    if not is_nil(opts[:public_key]) and
         not Enum.any?([:generate, :material, :new_secret_ref], &Keyword.has_key?(opts, &1)) do
      with {:ok, _pin} <- PublicKey.new(opts[:public_key], opts[:kind]),
           do: {:ok, [], nil}
    else
      with {:ok, spec, disclosure} <- source_input(opts), do: {:ok, [spec], disclosure}
    end
  end

  defp source_previous(opts, current) do
    if Keyword.has_key?(opts, :previous),
      do: previous_spec(opts, current, opts[:previous_retires_at]),
      else: {:ok, []}
  end

  defp previous_spec(opts, current, %DateTime{}) do
    kind = Keyword.get(opts, :previous_kind, previous_kind(current))

    with {:ok, spec, nil} <- source_input(material: opts[:previous], kind: kind),
         do: {:ok, [%{spec | field: :previous_secret_ref, kind_field: :previous_secret_kind}]}
  end

  defp previous_spec(_opts, _current, nil), do: {:error, :previous_secret_undated}
  defp previous_spec(_opts, _current, _invalid), do: {:error, :invalid_retirement_time}
  defp previous_kind([spec]), do: spec.kind
  defp previous_kind([]), do: nil

  defp create_owner(resource, attrs, issued, opts) do
    action = Keyword.get(opts, :action, Info.primary_action!(resource, :create).name)

    attributes =
      issued
      |> KeyIssuing.attributes()
      |> Map.put(:secret_created_at, Transitions.now(opts))
      |> Map.put(:secret_first_used_at, nil)
      |> creation_attributes(resource, issued, opts)

    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(
      Map.merge(Storage.context(resource), %{ash_hooks_issued_attributes: attributes})
    )
    # Ash supplies the source tenant attribute when the create action runs.
    |> Ash.Changeset.for_create(action, attrs,
      tenant: opts[:tenant],
      require?: Storage.section(resource) != :inbound_source
    )
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

  defp creation_attributes(attributes, resource, issued, opts) do
    if Storage.section(resource) == :inbound_source do
      attributes =
        if opts[:public_key],
          do:
            Map.merge(attributes, %{
              public_key: opts[:public_key],
              public_key_kind: opts[:kind],
              secret_created_at: nil
            }),
          else: attributes

      if Enum.any?(issued, &(&1.field == :previous_secret_ref)),
        do:
          Map.merge(attributes, %{
            previous_secret_created_at: Transitions.now(opts),
            previous_secret_first_used_at: nil,
            previous_secret_retired_at: opts[:previous_retires_at]
          }),
        else: attributes
    else
      tenant_attributes(attributes, resource, opts[:tenant])
    end
  end

  defp input(opts, slot, resource) do
    if Storage.section(resource) == :inbound_source do
      source_input(opts)
    else
      case Enum.filter([:generate, :material, :new_secret_ref], &Keyword.has_key?(opts, &1)) do
        [:generate] -> generate(opts[:generate], slot)
        [:material] -> decode(opts[:material], slot)
        _ -> {:error, :key_input_required}
      end
    end
  end

  defp source_input(opts) do
    case Enum.filter(
           [:generate, :material, :new_secret_ref, :public_key],
           &Keyword.has_key?(opts, &1)
         ) do
      [:generate] ->
        source_generate(opts[:generate])

      [:material] ->
        if source_kind?(opts[:kind]) and is_binary(opts[:material]) and opts[:material] != "",
          do: {:ok, spec(:standard, opts[:kind], opts[:material]), nil},
          else: {:error, :invalid_material}

      _ ->
        {:error, :key_input_required}
    end
  end

  defp source_kind?({:standard_webhooks, version}), do: version in [:v1, :v1a]
  defp source_kind?({:sender_hmac, digest}), do: digest in [:sha1, :sha256, :sha384, :sha512]
  defp source_kind?({:legacy_hmac, :sha256}), do: true
  defp source_kind?(_), do: false

  defp source_generate({:standard_webhooks, :v1} = kind), do: generate(kind, :standard)
  defp source_generate(_), do: {:error, :kind_not_allowed}

  defp generate(kind, slot, resource) do
    if Storage.section(resource) == :inbound_source,
      do: source_generate(kind),
      else: generate(kind, slot)
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
