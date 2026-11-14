defmodule AshHooks.Test.KeyIssuingCases do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias AshHooks.{Endpoint, KeyRegistry, Signing}
  alias AshHooks.KeyRegistry.{Storage, Transitions}
  alias AshHooks.Test.{CustodySigningCases, InboundSourceCases, KeyRegistryCases, RealReceiver}

  @kind {:standard_webhooks, :v1}
  @clock ~U[2026-11-14 12:00:00.000000Z]
  @body ~s({"event":"checked"})

  def setup_all(module, layer, repo, prefix) do
    ctx = CustodySigningCases.setup_all(module, layer, repo, prefix)
    endpoint = Module.concat(module, IssuingEndpoint)

    compile_owner(ctx, endpoint,
      custodian: AshHooks.Test.IssuingCustodian,
      secret_resolver: {__MODULE__, :resolve}
    )

    %{ctx | endpoint: endpoint}
  end

  def clean(ctx) do
    CustodySigningCases.clean(ctx)
    Application.put_env(:ash_hooks, :issuing_custodian, {ctx.custodian, self(), ctx.repo})
    Application.put_env(:ash_hooks, :issuing_bytes, %{})

    on_exit(fn ->
      Application.delete_env(:ash_hooks, :issuing_custodian)
      Application.delete_env(:ash_hooks, :issuing_bytes)
    end)

    :ok
  end

  def cases do
    [
      :outer_transaction,
      :create_generated_and_imported,
      :create_failure,
      :creation_timestamps,
      :persisted_primary_keys,
      :owner_mismatch,
      :identity_conflict,
      :direct_reference_guard,
      :direct_kind_guard,
      :input_validation,
      :unscoped_creation,
      :roll_allowed_kinds,
      :roll_material,
      :roll_refusals,
      :roll_overlap_and_disposal,
      :concurrent_rolls,
      :half_adopted_byte_roll,
      :reissue_overlap,
      :reissue_refusals,
      :retained_reference,
      :owner_write_failure,
      :concurrent_reissue_roll,
      :adoption,
      :partial_adoption,
      :adoption_refusals,
      :adoption_resolvers,
      :adoption_store_failure,
      :store_results,
      :cleanup_failure_keeps_cause,
      :store_crash_recovery,
      :lost_owner_cas,
      :lost_registry_cas,
      :create_sweep_race,
      :adoption_race,
      :two_tenants
    ]
  end

  def receiver_cases,
    do: [
      :create_generated_and_imported,
      :roll_allowed_kinds,
      :roll_material,
      :reissue_overlap,
      :adoption,
      :partial_adoption
    ]

  def outer_transaction(ctx) do
    owner = byte_owner!(ctx)

    assert {:ok, :ok} =
             ctx.repo.transaction(fn ->
               for operation <- [
                     fn -> Endpoint.create_with_key(ctx.endpoint, %{}) end,
                     fn -> Endpoint.reissue_secret(owner) end,
                     fn -> Endpoint.adopt_keys(owner) end,
                     fn -> create(ctx) end,
                     fn -> Endpoint.roll_secret(owner, tenant: 17, generate: @kind) end,
                     fn -> Endpoint.reissue_secret(owner, tenant: 17) end,
                     fn -> Endpoint.adopt_keys(owner, tenant: 17) end
                   ] do
                 assert {:error, :inside_transaction} = operation.()
               end

               :ok
             end)

    assert rows(ctx) == []
    refute_received {:store, _, _, _}
  end

  def create_generated_and_imported(ctx) do
    for kind <- [@kind, {:standard_webhooks, :v1a}] do
      assert {:ok, owner, disclosure} = create(ctx, generate: kind)
      assert owner.secret_kind == kind
      assert owner.secret_created_at == @clock
      assert owner.secret_first_used_at == nil
      assert [row] = Enum.filter(rows(ctx), &(&1.ref == owner.secret_ref))
      assert row.state == :attached
      assert row.owner_key == AshHooks.PrimaryKey.encode(owner)
      assert row.custody_tenant == "17"
      key = custody_key(ctx, owner, :secret_ref, :secret_kind)
      assert {:ok, signature} = AshHooks.Custody.sign(key, @body)
      assert :ok = AshHooks.Custody.verify(key, @body, signature)
      assert {:ok, _} = AshHooks.Custody.display_fingerprint(key)

      if kind == {:standard_webhooks, :v1a},
        do: assert({:ok, _} = key.custodian.public_key(key.ref, key.tenant, key.kind))

      assert_disclosure(ctx, owner, disclosure)
    end

    material = Signing.generate_secret()
    assert {:ok, owner} = create(ctx, material: material)
    assert_disclosure(ctx, owner, material)
  end

  def create_failure(ctx) do
    assert {:error, _} = create(ctx, attrs: %{url: "invalid"})
    assert [row] = rows(ctx)
    assert row.state == :retired
    assert row.owner_key == nil
    assert Ash.read!(ctx.endpoint, tenant: 17, authorize?: false) == []
  end

  def creation_timestamps(ctx) do
    resource = Module.concat(ctx.endpoint, TimestampOwner)

    attributes =
      quote do
        attribute :tenant_id, :integer, allow_nil?: false, public?: true

        attribute :secret_first_used_at, :utc_datetime_usec,
          default: unquote(Macro.escape(@clock))
      end

    compile_owner(Map.put(ctx, :endpoint_attributes, attributes), resource,
      custodian: AshHooks.Test.IssuingCustodian
    )

    assert {:ok, owner, _} = create(%{ctx | endpoint: resource})
    assert owner.secret_created_at == @clock
    assert owner.secret_first_used_at == nil
  end

  def persisted_primary_keys(ctx) do
    for shape <- [:composite, :non_writable, :change_key, :return_other_key] do
      resource = Module.concat(ctx.endpoint, "Owner#{shape}")

      attributes =
        quote do
          attribute(:tenant_id, :integer,
            allow_nil?: false,
            public?: true,
            primary_key?: unquote(shape == :composite)
          )

          attribute(:id, :uuid,
            allow_nil?: false,
            public?: true,
            primary_key?: true,
            writable?: unquote(shape != :non_writable),
            default: &Ash.UUID.generate/0
          )
        end

      changes =
        quote do
          changes do
            change(AshHooks.Test.IssuingCreateChange, on: [:create])
          end
        end

      configured =
        ctx |> Map.put(:endpoint_attributes, attributes) |> Map.put(:endpoint_changes, changes)

      compile_owner(configured, resource, custodian: AshHooks.Test.IssuingCustodian)

      Process.put(:issuing_create_change, shape)
      assert {:ok, owner, _} = create(%{ctx | endpoint: resource})
      persisted = Ash.read_one!(resource, tenant: 17, authorize?: false)
      assert owner.id == persisted.id
      assert stored(ctx, owner.secret_ref).owner_key == AshHooks.PrimaryKey.encode(persisted)

      if ctx[:source_owner?] do
        assert {:ok, rolled, _} =
                 AshHooks.InboundSource.roll_secret(persisted, tenant: 17, generate: @kind)

        assert stored(ctx, rolled.secret_ref).owner_key == AshHooks.PrimaryKey.encode(persisted)
      end

      ctx.repo.query!("DELETE FROM #{ctx.endpoint_table}", [], log: false)
    end
  end

  def owner_mismatch(ctx) do
    resource = Module.concat(ctx.endpoint, MismatchedOwner)

    changes =
      quote do
        changes do
          change(AshHooks.Test.IssuingCreateChange, on: [:create])
        end
      end

    compile_owner(Map.put(ctx, :endpoint_changes, changes), resource,
      custodian: AshHooks.Test.IssuingCustodian
    )

    for mutation <- [:replace_ref, :replace_kind] do
      Process.put(:issuing_create_change, mutation)
      assert {:error, :owner_mismatch} = create(%{ctx | endpoint: resource})
      assert Ash.read!(resource, tenant: 17, authorize?: false) == []
      assert Enum.all?(rows(ctx), &(&1.state == :retired))
    end
  end

  def identity_conflict(ctx) do
    resource = Module.concat(ctx.endpoint, UniqueOwner)

    identities =
      quote do
        identities do
          identity(:unique_url, [:url])
        end
      end

    compile_owner(Map.put(ctx, :endpoint_identities, identities), resource,
      custodian: AshHooks.Test.IssuingCustodian
    )

    index = ctx.endpoint_table <> "_unique_url_index"

    ctx.repo.query!("CREATE UNIQUE INDEX #{index} ON #{ctx.endpoint_table} (url, tenant_id)", [],
      log: false
    )

    on_exit(fn -> ctx.repo.query!("DROP INDEX #{index}", [], log: false) end)

    outcomes =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> create(%{ctx | endpoint: resource}) end) end)
      |> Enum.map(&Task.await(&1, 15_000))

    assert Enum.count(outcomes, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(outcomes, &match?({:error, _}, &1)) == 1
    assert Enum.count(rows(ctx), &(&1.state == :attached)) == 1
    assert Enum.count(rows(ctx), &(&1.state == :retired)) == 1
  end

  def direct_reference_guard(ctx) do
    resource = Module.concat(ctx.endpoint, WithoutResolver)

    compile_owner(ctx, resource,
      custodian: AshHooks.Test.IssuingCustodian,
      secret_resolver: nil
    )

    assert {:error, _} =
             Ash.create(resource, %{url: url(), tenant_id: 17, secret_ref: "host"},
               tenant: 17,
               authorize?: false
             )

    assert {:ok, _, _} =
             Endpoint.create_with_key(resource, %{url: url()}, tenant: 17, generate: @kind)

    for attrs <- [
          %{url: url(), secret_ref: "host"},
          %{"url" => url(), "legacy_secret_ref" => "host-legacy"}
        ] do
      assert elem(Endpoint.create_with_key(resource, attrs, tenant: 17, generate: @kind), 0) ==
               :error
    end

    {:ok, owner, _} =
      Endpoint.create_with_key(resource, %{url: url()}, tenant: 17, generate: @kind)

    assert {:error, :secret_resolver_required} =
             Endpoint.roll_secret(owner, tenant: 17, new_secret_ref: "host-next")

    assert {:error, :secret_resolver_required} =
             Endpoint.roll_secret(owner,
               tenant: 17,
               new_secret_ref: "host-next",
               new_secret_kind: @kind
             )

    byte = Module.concat(ctx.endpoint, ByteResource)
    compile_owner(ctx, byte, custodian: nil, key_registry: nil)
    assert byte_owner!(%{ctx | endpoint: byte}).secret_ref == "byte-current"

    assert {:error, :custody_required} =
             Endpoint.create_with_key(byte, %{url: url()}, tenant: 17, generate: @kind)
  end

  def direct_kind_guard(ctx) do
    fields = [
      :secret_kind,
      :previous_secret_kind,
      :legacy_secret_kind,
      :legacy_previous_secret_kind
    ]

    owner = Module.concat(ctx.endpoint, HostKindInputs)
    accepted = [:url, :tenant_id, :secret_ref | fields]

    compile_owner(
      Map.put(ctx, :endpoint_defaults, [:read, :destroy, create: accepted, update: accepted]),
      owner, custodian: AshHooks.Test.IssuingCustodian, secret_resolver: {__MODULE__, :resolve})

    for field <- fields, string_keys? <- [false, true] do
      attrs = Map.put(%{url: url(), tenant_id: 17, secret_ref: "host-byte"}, field, @kind)

      attrs =
        if string_keys?, do: Map.new(attrs, fn {k, v} -> {Atom.to_string(k), v} end), else: attrs

      assert {:error, _} = Ash.create(owner, attrs, tenant: 17, authorize?: false)
      assert {:error, _} = Endpoint.create_with_key(owner, attrs, tenant: 17, generate: @kind)
    end

    assert {:ok, row} =
             Ash.create(
               owner,
               %{url: url(), tenant_id: 17, secret_ref: "host-byte"},
               tenant: 17,
               authorize?: false
             )

    assert row.secret_ref == "host-byte"
    assert row.secret_kind == nil
    for field <- fields do
      assert {:error, _} = Ash.update(row, %{field => @kind}, tenant: 17, authorize?: false)
    end
    assert {:ok, row} = Ash.update(row, %{secret_ref: "next-byte"}, tenant: 17, authorize?: false)
    assert row.secret_ref == "next-byte"
    assert row.secret_kind == nil
  end

  def input_validation(ctx) do
    assert {:error, :key_input_required} =
             Endpoint.create_with_key(ctx.endpoint, %{url: url()}, tenant: 17)

    for material <- [nil, 123, "whsec_invalid!"] do
      assert {:error, :invalid_material} =
               Endpoint.create_with_key(ctx.endpoint, %{url: url()},
                 tenant: 17,
                 material: material
               )
    end

    assert rows(ctx) == []
    material = :crypto.strong_rand_bytes(32)
    assert {:ok, owner} = create(ctx, material: Base.encode64(material, padding: false))
    assert {:ok, _} = ctx.custodian.sign(owner.secret_ref, "17", @kind, @body)

    assert {:error, :invalid_material} =
             Endpoint.roll_secret(owner, tenant: 17, slot: :legacy, material: "")
  end

  def unscoped_creation(ctx) do
    registry = Module.concat(ctx.endpoint, GlobalRegistry)
    resource = Module.concat(ctx.endpoint, GlobalOwner)
    configured = %{ctx | registry: registry, endpoint: resource} |> Map.put(:tenancy?, false)
    KeyRegistryCases.compile_registry(configured)

    compile_owner(configured, resource,
      custodian: AshHooks.Test.IssuingCustodian,
      tenancy?: false
    )

    on_exit(fn ->
      for module <- [registry, resource] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    assert {:ok, owner, _} =
             Endpoint.create_with_key(resource, %{url: url(), tenant_id: 17}, generate: @kind)

    [row] = Ash.read!(registry, authorize?: false)
    assert row.ref == owner.secret_ref
    assert row.custody_tenant == nil
  end

  def roll_allowed_kinds(ctx) do
    for {slot, kind} <- [
          {:standard, @kind},
          {:standard, {:standard_webhooks, :v1a}},
          {:legacy, {:legacy_hmac, :sha256}}
        ] do
      {:ok, owner, _} = create(ctx)

      assert {:ok, rolled, disclosure} =
               Endpoint.roll_secret(owner, tenant: 17, slot: slot, generate: kind, now: @clock)

      fields = AshHooks.KeyLifecycle.fields(slot)
      assert Map.fetch!(rolled, fields.kind) == kind
      assert Map.fetch!(rolled, fields.ref) != Map.get(owner, fields.ref)
      assert_disclosure(ctx, rolled, disclosure, slot)

      assert {:ok, reissued, next_disclosure} =
               Endpoint.reissue_secret(rolled, tenant: 17, slot: slot)

      assert Map.fetch!(reissued, fields.kind) == kind
      assert Map.get(reissued, fields.previous_ref) == Map.get(rolled, fields.previous_ref)
      assert_disclosure(ctx, reissued, next_disclosure, slot)
    end
  end

  def roll_material(ctx) do
    for {slot, material} <- [
          standard: Signing.generate_secret(),
          standard: elem(Signing.generate_signing_keypair(), 0),
          legacy: "whsec_legacy-as-issued"
        ] do
      {:ok, owner, _} = create(ctx)

      assert {:ok, rolled} =
               Endpoint.roll_secret(owner, tenant: 17, slot: slot, material: material)

      disclosure =
        if String.starts_with?(material, "whsk_"),
          do: public_half(material),
          else: material

      assert_disclosure(ctx, rolled, disclosure, slot)
    end
  end

  def roll_refusals(ctx) do
    {:ok, owner, _} = create(ctx)
    count = length(rows(ctx))

    for kind <- [{:sender_hmac, :sha256}, {:legacy_hmac, :sha256}, :invalid] do
      assert {:error, :kind_not_allowed} =
               Endpoint.roll_secret(owner, tenant: 17, generate: kind)
    end

    for options <- [[], [generate: @kind, material: Signing.generate_secret()]] do
      assert {:error, :key_input_required} =
               Endpoint.roll_secret(owner, [tenant: 17] ++ options)
    end

    assert length(rows(ctx)) == count

    assert {:error, :invalid_overlap} =
             Endpoint.roll_secret(owner, tenant: 17, generate: @kind, overlap_seconds: -1)
  end

  def roll_overlap_and_disposal(ctx) do
    {:ok, owner, _} = create(ctx)

    {:ok, rolled, _} =
      Endpoint.roll_secret(owner, tenant: 17, generate: @kind, now: @clock, overlap_seconds: 10)

    assert rolled.previous_secret_kind == owner.secret_kind

    assert {:error, :overlap_active} =
             Endpoint.roll_secret(rolled, tenant: 17, generate: @kind, now: @clock)

    assert {:ok, _, _} =
             Endpoint.roll_secret(rolled,
               tenant: 17,
               generate: @kind,
               now: DateTime.add(@clock, 10)
             )

    assert stored(ctx, owner.secret_ref).state == :retired
    sweep!(ctx)
    assert stored(ctx, owner.secret_ref).state == :destroyed
  end

  def concurrent_rolls(ctx) do
    {:ok, owner, _} = create(ctx)

    race([
      fn -> Endpoint.roll_secret(owner, tenant: 17, generate: @kind) end,
      fn -> Endpoint.roll_secret(owner, tenant: 17, generate: @kind) end
    ])
  end

  def half_adopted_byte_roll(ctx) do
    {:ok, owner, _} = create(ctx)
    owner = update!(owner, legacy_secret_ref: "legacy-byte")
    before = rows(ctx)

    assert {:ok, rolled} =
             Endpoint.roll_secret(owner, tenant: 17, slot: :legacy, new_secret_ref: "next-byte")

    assert rolled.legacy_previous_secret_ref == "legacy-byte"
    assert rolled.legacy_secret_kind == nil
    assert rows(ctx) == before
  end

  def reissue_overlap(ctx) do
    {:ok, owner, _} = create(ctx)
    {:ok, rolled, _} = Endpoint.roll_secret(owner, tenant: 17, generate: @kind)
    assert {:ok, reissued, disclosure} = Endpoint.reissue_secret(rolled, tenant: 17)
    assert reissued.previous_secret_ref == rolled.previous_secret_ref
    assert reissued.previous_secret_retired_at == rolled.previous_secret_retired_at
    assert stored(ctx, rolled.secret_ref).state == :retired
    sweep!(ctx)
    assert stored(ctx, rolled.secret_ref).state == :destroyed
    assert_disclosure(ctx, reissued, disclosure)
  end

  def reissue_refusals(ctx) do
    owner = byte_owner!(ctx)
    assert {:error, :byte_slot} = Endpoint.reissue_secret(owner, tenant: 17)
    owner = update!(owner, secret_kind: {:sender_hmac, :sha256})
    assert {:error, :kind_not_allowed} = Endpoint.reissue_secret(owner, tenant: 17)
    assert rows(ctx) == []
  end

  def retained_reference(ctx) do
    {:ok, owner, _} = create(ctx)

    owner =
      update!(owner,
        previous_secret_ref: owner.secret_ref,
        previous_secret_kind: owner.secret_kind,
        previous_secret_retired_at: DateTime.add(DateTime.utc_now(), 120)
      )

    assert {:ok, reissued, _} = Endpoint.reissue_secret(owner, tenant: 17)
    assert reissued.previous_secret_ref == owner.secret_ref
    assert stored(ctx, owner.secret_ref).state == :attached
  end

  def owner_write_failure(ctx) do
    resource = Module.concat(ctx.endpoint, ValidatedOwner)
    field = if ctx[:source_owner?], do: :paused, else: :status
    value = if ctx[:source_owner?], do: true, else: :disabled

    changes =
      quote do
        validations do
          validate(attribute_equals(unquote(field), unquote(value)), on: [:update])
        end
      end

    compile_owner(Map.put(ctx, :endpoint_changes, changes), resource,
      custodian: AshHooks.Test.IssuingCustodian
    )

    configured = %{ctx | endpoint: resource}
    assert {:ok, owner, _} = create(configured)
    assert {:error, _} = owner_api(ctx).reissue_secret(owner, tenant: 17)
    assert stored(ctx, owner.secret_ref).state == :attached
    assert Enum.count(rows(ctx), &(&1.state == :retired)) == 1

    if ctx[:source_owner?] do
      assert {:error, _} = AshHooks.InboundSource.unpause(owner, tenant: 17)
      assert {:error, :rolled_underneath} = AshHooks.InboundSource.pause(owner, tenant: 18)
      assert {:error, :tenant_required} = AshHooks.InboundSource.pause(owner)
    end
  end

  def concurrent_reissue_roll(ctx) do
    {:ok, owner, _} = create(ctx)

    race([
      fn -> Endpoint.reissue_secret(owner, tenant: 17) end,
      fn -> Endpoint.roll_secret(owner, tenant: 17, generate: @kind) end
    ])
  end

  def adoption(ctx) do
    owner =
      byte_owner!(ctx,
        previous_secret_ref: "byte-previous",
        previous_secret_retired_at: DateTime.add(@clock, 60),
        secret_created_at: @clock,
        secret_first_used_at: @clock,
        previous_secret_created_at: DateTime.add(@clock, -60),
        previous_secret_first_used_at: DateTime.add(@clock, -30),
        legacy_secret_ref: "legacy-current",
        legacy_previous_secret_ref: "legacy-previous",
        legacy_previous_secret_retired_at: DateTime.add(@clock, 120)
      )

    bytes = %{
      "byte-current" => Signing.generate_secret(),
      "byte-previous" => elem(Signing.generate_signing_keypair(), 0),
      "legacy-current" => "legacy current",
      "legacy-previous" => "legacy previous"
    }

    Application.put_env(:ash_hooks, :issuing_bytes, bytes)

    assert {:ok, adopted} = Endpoint.adopt_keys(owner, tenant: 17)

    for {field, kind_field} <- Transitions.slots(ctx.endpoint) do
      assert Map.get(adopted, kind_field)
      original = Map.fetch!(bytes, Map.fetch!(owner, field))
      key = custody_key(ctx, adopted, field, kind_field)
      timestamp = System.system_time(:second)

      assert_same_signature(field, key, original, timestamp)
    end

    for {field, value} <- Map.from_struct(owner),
        String.ends_with?(Atom.to_string(field), "_at"),
        do: assert(Map.get(adopted, field) == value)

    before = rows(ctx)
    assert {:ok, ^adopted} = Endpoint.adopt_keys(adopted, tenant: 17)
    assert rows(ctx) == before
    refute Enum.any?(rows(ctx), &Map.has_key?(bytes, &1.ref))
    receiver_check(ctx, adopted, bytes["byte-current"])
    receiver_check(ctx, adopted, bytes["legacy-current"], :legacy)
  end

  defp assert_same_signature(field, key, original, timestamp)
       when field in [:secret_ref, :previous_secret_ref] do
    byte_signer =
      if String.starts_with?(original, "whsk_"),
        do: &Signing.sign_ed25519/4,
        else: &Signing.sign/4

    assert Signing.sign("msg_fixed", timestamp, @body, key) ==
             byte_signer.("msg_fixed", timestamp, @body, original)
  end

  defp assert_same_signature(_field, key, original, timestamp) do
    assert AshHooks.Legacy.headers(key, nil, @body, timestamp) ==
             AshHooks.Legacy.headers(original, nil, @body, timestamp)
  end

  def partial_adoption(ctx) do
    {:ok, owner, disclosure} = create(ctx)
    material = Signing.generate_secret()
    Application.put_env(:ash_hooks, :issuing_bytes, %{"byte-previous" => material})

    owner =
      update!(owner,
        previous_secret_ref: "byte-previous",
        previous_secret_retired_at: DateTime.add(DateTime.utc_now(), 120)
      )

    receiver_check(ctx, owner, disclosure)
    receiver_check(ctx, owner, material)
    assert {:ok, adopted} = Endpoint.adopt_keys(owner, tenant: 17)
    assert adopted.secret_ref == owner.secret_ref
    assert adopted.secret_kind == owner.secret_kind
    assert adopted.previous_secret_ref != owner.previous_secret_ref
    assert Enum.count(rows(ctx), &(&1.state == :attached)) == 2
    receiver_check(ctx, adopted, disclosure)
    receiver_check(ctx, adopted, material)
  end

  def adoption_refusals(ctx) do
    owner = byte_owner!(ctx, previous_secret_ref: "undated")
    assert {:error, :previous_secret_undated} = Endpoint.adopt_keys(owner, tenant: 17)
    assert rows(ctx) == []
  end

  def adoption_resolvers(ctx) do
    owner = byte_owner!(ctx)
    resource = Module.concat(ctx.endpoint, NoByteResolver)

    compile_owner(ctx, resource,
      custodian: AshHooks.Test.IssuingCustodian,
      secret_resolver: nil
    )

    owner_without_resolver = Ash.get!(resource, owner.id, tenant: 17, authorize?: false)

    assert {:error, :secret_resolver_required} =
             Endpoint.adopt_keys(owner_without_resolver, tenant: 17)

    Application.put_env(:ash_hooks, :issuing_bytes, %{
      "byte-current" => {:error, :private_backend}
    })

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             Endpoint.adopt_keys(owner, tenant: 17)

    Application.put_env(:ash_hooks, :issuing_bytes, %{"byte-current" => Signing.generate_secret()})

    assert {:ok, adopted} = Endpoint.adopt_keys(owner, tenant: 17, tenant_aware_secrets: true)
    assert_receive {:resolve, "byte-current", 17}
    assert {:error, :rolled_underneath} = Endpoint.adopt_keys(adopted, tenant: 18)
  end

  def adoption_store_failure(ctx) do
    owner =
      byte_owner!(ctx, previous_secret_ref: "byte-previous", previous_secret_retired_at: @clock)

    Application.put_env(:ash_hooks, :issuing_bytes, %{
      "byte-current" => Signing.generate_secret(),
      "byte-previous" => Signing.generate_secret()
    })

    Process.put(:issuing_store_answer, {:next_store, {:error, :invalid_material}})
    assert {:error, :invalid_material} = Endpoint.adopt_keys(owner, tenant: 17)
    assert length(rows(ctx)) == 2
    assert Enum.all?(rows(ctx), &(&1.state == :retired))

    assert Ash.get!(ctx.endpoint, owner.id, tenant: 17, authorize?: false).secret_ref ==
             owner.secret_ref

    sweep!(ctx)
    assert Enum.all?(rows(ctx), &(&1.state == :destroyed))
  end

  def store_results(ctx) do
    sink = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:ash_hooks, :endpoint, :roll], [:ash_hooks, :key_registry, :destroy_failed]],
        fn event, measurements, metadata, _ ->
          send(sink, {:issued_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {answer, expected} <- [
          {{:error, :invalid_material}, :invalid_material},
          {{:error, :ref_destroyed}, :key_issue_expired},
          {{:error, :ref_exists}, AshHooks.Errors.Unknown.UnknownError},
          {{:error, :unavailable}, AshHooks.Errors.Unknown.KeyUnavailable},
          {{:raise, "private_backend"}, AshHooks.Errors.Unknown.UnknownError},
          {{:exit, "private_backend"}, AshHooks.Errors.Unknown.UnknownError},
          {{:throw, "private_backend"}, AshHooks.Errors.Unknown.UnknownError},
          {{:error, {:private_backend, "private_backend"}}, AshHooks.Errors.Unknown.UnknownError}
        ] do
      Process.put(:issuing_store_answer, answer)
      assert {:error, error} = create(ctx)
      if is_atom(error), do: assert(error == expected), else: assert(error.__struct__ == expected)
      refute inspect(error) =~ "private_backend"
    end

    assert Enum.all?(rows(ctx), &(&1.state == :retired))
    refute_receive {:issued_event, _, _, _}
    {:ok, owner, _} = create(ctx)
    assert {:ok, _, disclosure} = Endpoint.roll_secret(owner, tenant: 17, generate: @kind)

    assert_receive {:issued_event, [:ash_hooks, :endpoint, :roll], %{},
                    %{endpoint_id: id} = metadata}

    assert id == owner.id
    assert map_size(metadata) == 1
    refute inspect(metadata) =~ disclosure
  end

  def cleanup_failure_keeps_cause(ctx) do
    registry = Module.concat(ctx.registry, CleanupFailure)
    endpoint = Module.concat(ctx.endpoint, CleanupFailure)

    configured =
      %{ctx | registry: registry, endpoint: endpoint}
      |> Map.put(:registry_repo, &KeyRegistryCases.repo/2)

    Process.put(:registry_wrong_repo, ctx.repo)
    KeyRegistryCases.compile_registry(configured)
    compile_owner(configured, endpoint, custodian: AshHooks.Test.IssuingCustodian)

    on_exit(fn ->
      for module <- [registry, endpoint] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    Process.put(:issuing_store_answer, :break_cleanup)
    assert {:error, %AshHooks.Errors.Unknown.KeyUnavailable{}} = create(configured)
    Process.put(:registry_wrong_repo, ctx.repo)
    assert [%{state: :issued}] = rows(configured)
    sweep!(configured)
    assert [%{state: :destroyed}] = rows(configured)
  end

  def store_crash_recovery(ctx) do
    resource = Module.concat(ctx.endpoint, CrashingOwner)

    changes =
      quote do
        changes do
          change(AshHooks.Test.IssuingCreateChange, on: [:create])
        end
      end

    compile_owner(Map.put(ctx, :endpoint_changes, changes), resource,
      custodian: AshHooks.Test.IssuingCustodian
    )

    for point <- [:before_store, :after_store, :after_owner_write] do
      {pid, monitor} =
        spawn_monitor(fn ->
          crash_at(point)
          create(%{ctx | endpoint: resource})
        end)

      expected = if point == :after_owner_write, do: :issuing_crash, else: :killed
      assert_receive {:DOWN, ^monitor, :process, ^pid, ^expected}, 15_000
      assert Enum.any?(rows(ctx), &(&1.state == :issued))
      assert Ash.read!(resource, tenant: 17, authorize?: false) == []
      sweep!(ctx)
      assert Enum.all?(rows(ctx), &(&1.state == :destroyed))
    end
  end

  defp crash_at(:after_owner_write), do: Process.put(:issuing_create_change, :crash_after_write)
  defp crash_at(point), do: Process.put(:issuing_store_answer, {:crash, point})

  def lost_owner_cas(ctx) do
    {:ok, owner, _} = create(ctx)
    {:ok, _, _} = owner_api(ctx).roll_secret(owner, tenant: 17, generate: @kind)

    assert {:error, :rolled_underneath} =
             owner_api(ctx).roll_secret(owner, tenant: 17, generate: @kind)

    assert Enum.count(rows(ctx), &(&1.state == :retired)) == 1
  end

  def lost_registry_cas(ctx) do
    Process.put(:issuing_store_answer, {:sweep, ctx})
    assert {:error, :key_issue_expired} = create(ctx)
    assert Ash.read!(ctx.endpoint, tenant: 17, authorize?: false) == []
    assert Enum.all?(rows(ctx), &(&1.state == :destroyed))
  end

  def create_sweep_race(ctx) do
    parent = self()

    for order <- [:attach, :sweep, :race] do
      opts =
        if ctx[:source_owner?],
          do: [attrs: %{url: url(), account_id: Atom.to_string(order)}],
          else: []

      create_task =
        Task.async(fn ->
          Process.put(:issuing_store_answer, {:pause, parent})
          create(ctx, opts)
        end)

      assert_receive {:stored, creator, ref}, 15_000
      result = finish_create_race(order, ctx, create_task, creator)
      assert_create_race(result, stored(ctx, ref), ctx)
    end
  end

  defp finish_create_race(:attach, ctx, task, creator) do
    send(creator, :continue)
    result = Task.await(task, 15_000)
    sweep!(ctx)
    assert {:ok, _, _} = result
    result
  end

  defp finish_create_race(:sweep, ctx, task, creator) do
    sweep!(ctx)
    send(creator, :continue)
    result = Task.await(task, 15_000)
    assert {:error, :key_issue_expired} = result
    result
  end

  defp finish_create_race(:race, ctx, task, creator) do
    sweep_task = Task.async(fn -> sweep!(ctx) end)
    send(creator, :continue)
    result = Task.await(task, 15_000)
    Task.await(sweep_task, 15_000)
    result
  end

  defp assert_create_race({:ok, owner, _}, row, _ctx) do
    assert row.state == :attached
    assert row.owner_key == AshHooks.PrimaryKey.encode(owner)
  end

  defp assert_create_race({:error, :key_issue_expired}, row, ctx) do
    assert row.state == :destroyed

    refute Enum.any?(
             Ash.read!(ctx.endpoint, tenant: 17, authorize?: false),
             &(&1.secret_ref == row.ref)
           )
  end

  def adoption_race(ctx) do
    owner = byte_owner!(ctx)

    Application.put_env(:ash_hooks, :issuing_bytes, %{"byte-current" => Signing.generate_secret()})

    Process.put(:issuing_store_answer, {:roll, owner})
    assert {:error, :rolled_underneath} = Endpoint.adopt_keys(owner, tenant: 17)
    assert Enum.all?(rows(ctx), &(&1.state == :retired))
  end

  def two_tenants(ctx) do
    for tenant <- [17, 18] do
      assert {:ok, owner, _} = create(ctx, tenant: "0" <> Integer.to_string(tenant))
      assert {:ok, rolled, _} = Endpoint.roll_secret(owner, tenant: tenant, generate: @kind)
      assert {:ok, reissued, _} = Endpoint.reissue_secret(rolled, tenant: tenant)
      assert stored(ctx, reissued.secret_ref, tenant).custody_tenant == Integer.to_string(tenant)

      assert {:error, :unknown_ref} =
               ctx.custodian.sign(
                 reissued.secret_ref,
                 Integer.to_string(35 - tenant),
                 @kind,
                 @body
               )

      assert {:error, :rolled_underneath} =
               Endpoint.roll_secret(reissued, tenant: 35 - tenant, generate: @kind)

      Application.put_env(:ash_hooks, :issuing_bytes, %{
        "byte-current" => Signing.generate_secret()
      })

      byte = byte_owner!(ctx, [], tenant)
      assert {:ok, adopted} = Endpoint.adopt_keys(byte, tenant: tenant)
      assert stored(ctx, adopted.secret_ref, tenant).custody_tenant == Integer.to_string(tenant)

      assert {:error, :unknown_ref} =
               ctx.custodian.sign(
                 adopted.secret_ref,
                 Integer.to_string(35 - tenant),
                 @kind,
                 @body
               )

      canonical = Integer.to_string(tenant)

      for row <- rows(ctx, tenant) do
        assert_receive {:store, ref, ^canonical, _} when ref == row.ref
      end
    end
  end

  def real_delivery(ctx) do
    session = RealReceiver.open!()
    on_exit(fn -> RealReceiver.close!(session) end)

    for kind <- [@kind, {:standard_webhooks, :v1a}] do
      {:ok, owner, _} = create(ctx, attrs: %{url: RealReceiver.url(session)})
      {:ok, owner, disclosure} = Endpoint.roll_secret(owner, tenant: 17, generate: kind)
      {:ok, owner} = Endpoint.expire_previous_secret(owner, tenant: 17)

      assert {:ok, %{status: :succeeded, delivery: delivery}} =
               AshHooks.Delivery.test_send(owner,
                 deliveries: ctx.delivery,
                 tenant: 17,
                 type: :checked,
                 destination_policy: &CustodySigningCases.allow/2,
                 http_opts: [validate_destination: false]
               )

      request =
        Enum.find(RealReceiver.requests!(session), fn request ->
          Enum.any?(
            request["headers"],
            &(String.downcase(&1["name"]) == "webhook-id" and &1["value"] == delivery.event_uuid)
          )
        end)

      headers = Map.new(request["headers"], &{String.downcase(&1["name"]), &1["value"]})

      assert {:ok, _} =
               Signing.verify(
                 Base.decode64!(request["request_payload_base64"]),
                 headers,
                 disclosure
               )
    end
  end

  def resolve(ref) do
    case Application.fetch_env!(:ash_hooks, :issuing_bytes) |> Map.fetch!(ref) do
      {:error, _} = error -> error
      bytes -> {:ok, bytes}
    end
  end

  def resolve(ref, tenant) do
    send(self(), {:resolve, ref, tenant})
    resolve(ref)
  end

  def source_cases do
    [
      :create_failure,
      :creation_timestamps,
      :persisted_primary_keys,
      :owner_mismatch,
      :identity_conflict,
      :owner_write_failure,
      :store_crash_recovery,
      :lost_owner_cas,
      :lost_registry_cas,
      :create_sweep_race
    ]
  end

  defp owner_api(%{source_owner?: true}), do: AshHooks.InboundSource
  defp owner_api(_ctx), do: Endpoint

  defp compile_owner(ctx, resource, opts) do
    if ctx[:source_owner?],
      do: InboundSourceCases.compile_source(ctx, resource, opts),
      else: KeyRegistryCases.compile_endpoint(ctx, resource, opts)
  end

  defp create(ctx, opts \\ []) do
    {attrs, opts} = Keyword.pop(opts, :attrs, %{url: url()})
    opts = Keyword.merge([tenant: 17, now: @clock], opts)
    opts = if opts[:material], do: opts, else: Keyword.put_new(opts, :generate, @kind)

    if ctx[:source_owner?] do
      attrs = Map.merge(%{source: :checked, account_id: "account", provider: :first}, attrs)
      AshHooks.InboundSource.create_source(ctx.endpoint, attrs, opts)
    else
      Endpoint.create_with_key(ctx.endpoint, attrs, opts)
    end
  end

  defp byte_owner!(ctx, attrs \\ [], tenant \\ 17) do
    ctx.endpoint
    |> Ash.Changeset.for_create(
      :create,
      %{url: url(), tenant_id: tenant, secret_ref: "byte-current"},
      tenant: tenant
    )
    |> Ash.Changeset.force_change_attributes(Map.new(attrs))
    |> Ash.create!(authorize?: false)
  end

  defp update!(owner, attrs) do
    owner
    |> Ash.Changeset.for_update(:update, %{}, tenant: owner.tenant_id)
    |> Ash.Changeset.force_change_attributes(Map.new(attrs))
    |> Ash.update!(authorize?: false)
  end

  defp rows(ctx, tenant \\ 17), do: Ash.read!(ctx.registry, tenant: tenant, authorize?: false)
  defp stored(ctx, ref, tenant \\ 17), do: Enum.find(rows(ctx, tenant), &(&1.ref == ref))
  defp url, do: "https://hooks.example.test/issuing"

  defp sweep!(ctx),
    do:
      assert(
        {:ok, _} =
          KeyRegistry.sweep(ctx.registry, tenant: 17, now: DateTime.add(DateTime.utc_now(), 901))
      )

  defp custody_key(_ctx, owner, field, kind_field) do
    %AshHooks.Custody.Key{
      custodian: Storage.custodian(owner.__struct__),
      ref: Map.fetch!(owner, field),
      kind: Map.fetch!(owner, kind_field),
      tenant: Integer.to_string(owner.tenant_id)
    }
  end

  defp assert_disclosure(ctx, owner, disclosure, slot \\ :standard) do
    fields = AshHooks.KeyLifecycle.fields(slot)
    key = custody_key(ctx, owner, fields.ref, fields.kind)
    timestamp = System.system_time(:second)

    if slot == :standard do
      assert {:ok, _} =
               Signing.verify(
                 @body,
                 Signing.headers("msg_fixed", timestamp, @body, key),
                 disclosure
               )
    else
      headers = AshHooks.Legacy.headers(key, nil, @body, timestamp)

      assert {:ok, _} =
               AshHooks.Legacy.verify(
                 disclosure,
                 @body,
                 headers["x-webhook-signature"],
                 timestamp
               )
    end

    receiver_check(ctx, owner, disclosure, slot)
  end

  defp receiver_check(ctx, owner, disclosure, slot \\ :standard) do
    session = RealReceiver.open!()
    on_exit(fn -> RealReceiver.close!(session) end)
    owner = update!(owner, url: RealReceiver.url(session))

    assert {:ok, %{status: :succeeded}} =
             AshHooks.Delivery.test_send(owner,
               deliveries: ctx.delivery,
               tenant: owner.tenant_id,
               type: :checked,
               payload: @body,
               signing_mode: if(slot == :legacy, do: :legacy, else: :standard),
               destination_policy: &CustodySigningCases.allow/2,
               http_opts: [validate_destination: false]
             )

    [request] = RealReceiver.requests!(session)
    assert Base.decode64!(request["request_payload_base64"]) == @body
    headers = Map.new(request["headers"], &{String.downcase(&1["name"]), &1["value"]})

    if slot == :standard,
      do: assert({:ok, _} = Signing.verify(@body, headers, disclosure)),
      else:
        assert(
          {:ok, _} =
            AshHooks.Legacy.verify(
              disclosure,
              @body,
              headers["x-webhook-signature"],
              System.system_time(:second)
            )
        )
  end

  defp public_half("whsk_" <> encoded) do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, Base.decode64!(encoded))
    "whpk_" <> Base.encode64(public)
  end

  defp race(operations) do
    results = operations |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :rolled_underneath})) == 1
  end
end

defmodule AshHooks.Test.IssuingCustodian do
  @moduledoc false
  @behaviour AshHooks.Custody

  defp custodian, do: Application.fetch_env!(:ash_hooks, :issuing_custodian) |> elem(0)

  def store(ref, material, tenant, kind) do
    {custodian, sink, repo} = Application.fetch_env!(:ash_hooks, :issuing_custodian)
    false = repo.in_transaction?()
    send(sink, {:store, ref, tenant, kind})
    answer = Process.delete(:issuing_store_answer)
    if answer == {:crash, :before_store}, do: Process.exit(self(), :kill)
    result = custodian.store(ref, material, tenant, kind)

    case answer do
      nil ->
        result

      {:crash, :after_store} ->
        Process.exit(self(), :kill)

      {:raise, message} ->
        raise(message)

      {:exit, reason} ->
        exit(reason)

      {:throw, reason} ->
        throw(reason)

      :break_cleanup ->
        Process.put(:registry_wrong_repo, AshHooks.Test.RegistryOtherRepo)
        {:error, :unavailable}

      {:sweep, ctx} ->
        {:ok, _} =
          AshHooks.KeyRegistry.sweep(ctx.registry,
            tenant: 17,
            now: DateTime.add(DateTime.utc_now(), 901)
          )

        result

      {:roll, owner} ->
        {:ok, _} = AshHooks.Endpoint.roll_secret(owner, tenant: 17, new_secret_ref: "racing-byte")
        result

      {:next_store, answer} ->
        Process.put(:issuing_store_answer, answer)
        result

      {:pause, parent} ->
        send(parent, {:stored, self(), ref})

        receive do
          :continue -> result
        end

      other ->
        other
    end
  end

  def sign(ref, tenant, kind, input), do: custodian().sign(ref, tenant, kind, input)
  def verify(ref, tenant, kind, input, mac), do: custodian().verify(ref, tenant, kind, input, mac)
  def public_key(ref, tenant, kind), do: custodian().public_key(ref, tenant, kind)
  def fingerprint(ref, tenant, kind), do: custodian().fingerprint(ref, tenant, kind)
  def destroy(ref, tenant), do: custodian().destroy(ref, tenant)
end

defmodule AshHooks.Test.IssuingCreateChange do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Process.delete(:issuing_create_change) do
      :change_key ->
        Ash.Changeset.before_action(
          changeset,
          &Ash.Changeset.force_change_attribute(&1, :id, Ash.UUID.generate())
        )

      :return_other_key ->
        Ash.Changeset.after_action(changeset, fn _, row ->
          {:ok, %{row | id: Ash.UUID.generate()}}
        end)

      :replace_ref ->
        Ash.Changeset.before_action(
          changeset,
          &Ash.Changeset.force_change_attribute(&1, :secret_ref, "replaced")
        )

      :replace_kind ->
        Ash.Changeset.before_action(
          changeset,
          &Ash.Changeset.force_change_attribute(&1, :secret_kind, {:standard_webhooks, :v1a})
        )

      :crash_after_write ->
        Ash.Changeset.after_action(changeset, fn _, _ -> exit(:issuing_crash) end)

      _ ->
        changeset
    end
  end
end
