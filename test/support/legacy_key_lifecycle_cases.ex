defmodule AshHooks.Test.LegacyKeyLifecycleCases do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.Endpoint, as: Lifecycle
  alias AshHooks.Http.Bounded

  @clock ~U[2026-11-14 12:00:00.000000Z]
  @body ~s({"event":"rotation"})
  @fields [
    :legacy_secret_ref,
    :legacy_previous_secret_ref,
    :legacy_secret_created_at,
    :legacy_secret_first_used_at,
    :legacy_previous_secret_created_at,
    :legacy_previous_secret_first_used_at,
    :legacy_previous_secret_retired_at
  ]

  def cases do
    [
      :empty_incumbent,
      :active_overlap,
      :expire_then_roll,
      :ended_window,
      :concurrent_rolls,
      :invalid_overlap,
      :overlap_caps,
      :undated_previous,
      :scheduling_guards,
      :reference_validation,
      :slot_isolation,
      :stale_writes,
      :disabled_lifecycle
    ]
  end

  def receiver_cases do
    [
      :retired_signing,
      :overlap_signing,
      :undated_signing,
      :signing_race,
      :signing_modes,
      :zero_overlap_signing
    ]
  end

  def setup_all(test_module, layer, repo, prefix) do
    endpoint = Module.concat(test_module, Endpoint)
    delivery = Module.concat(test_module, Delivery)
    domain = Module.concat(test_module, Domain)
    storage = if layer == AshPostgres.DataLayer, do: :postgres, else: :sqlite
    endpoint_table = prefix <> "_endpoints"
    delivery_table = prefix <> "_deliveries"

    Code.compile_quoted(
      quote do
        unquote(
          endpoint_definition(endpoint, domain, layer, repo, storage, endpoint_table,
            legacy_key_lifecycle: :on
          )
        )

        unquote(delivery_definition(delivery, domain, layer, repo, storage, delivery_table))
        unquote(domain_definition(domain, [endpoint, delivery]))
      end
    )

    on_exit(fn -> purge([endpoint, delivery, domain]) end)
    create_tables(repo, storage, endpoint_table, delivery_table)

    %{
      endpoint: endpoint,
      delivery: delivery,
      domain: domain,
      layer: layer,
      repo: repo,
      storage: storage,
      endpoint_table: endpoint_table,
      delivery_table: delivery_table
    }
  end

  def clean(ctx) do
    ctx.repo.query!("DELETE FROM #{ctx.delivery_table}")
    ctx.repo.query!("DELETE FROM #{ctx.endpoint_table}")
    :ok
  end

  def empty_incumbent(ctx) do
    endpoint = endpoint!(ctx, legacy_secret_ref: nil)
    assert {:ok, rolled} = roll(endpoint, "installed")
    assert rolled.legacy_secret_ref == "installed"
    assert is_nil(rolled.legacy_previous_secret_ref)
    assert rolled.legacy_secret_created_at == @clock
    assert is_nil(rolled.legacy_previous_secret_created_at)
    assert is_nil(rolled.legacy_previous_secret_retired_at)
    assert is_nil(rolled.legacy_secret_first_used_at)
    assert {:ok, again} = roll(rolled, "next")
    assert again.legacy_previous_secret_ref == "installed"
  end

  def active_overlap(ctx) do
    endpoint = endpoint!(ctx)
    assert {:ok, rolled} = roll(endpoint, "next")
    before = stored(rolled)

    for caller <- [rolled, Map.put(rolled, :legacy_previous_secret_ref, nil)] do
      assert {:error, :overlap_active} = roll(caller, "third", now: DateTime.add(@clock, 59))
      assert stored(rolled) == before
    end
  end

  def expire_then_roll(ctx) do
    assert {:ok, rolled} = roll(endpoint!(ctx), "next")
    assert {:ok, expired} = Lifecycle.expire_previous_secret(rolled, slot: :legacy, now: @clock)
    assert is_nil(expired.legacy_previous_secret_ref)
    assert expired.legacy_previous_secret_retired_at == @clock
    assert {:ok, ^expired} = Lifecycle.expire_previous_secret(expired, slot: :legacy)
    assert {:ok, next} = roll(expired, "third")
    assert next.legacy_previous_secret_ref == "next"
  end

  def ended_window(ctx) do
    for offset <- [0, 1] do
      assert {:ok, rolled} = roll(endpoint!(ctx), "next")
      now = DateTime.add(@clock, 60 + offset)
      assert {:ok, next} = roll(rolled, "third", now: now)
      assert next.legacy_previous_secret_ref == "next"
      assert next.legacy_secret_created_at == now
      assert {:ok, 0} = Lifecycle.expire_previous_secrets(ctx.endpoint, slot: :legacy, now: now)

      assert {:ok, count} =
               Lifecycle.expire_previous_secrets(ctx.endpoint,
                 slot: :legacy,
                 now: DateTime.add(now, 60)
               )

      assert count >= 1
      assert is_nil(stored(next).legacy_previous_secret_ref)
    end
  end

  def concurrent_rolls(ctx) do
    endpoint = endpoint!(ctx)
    parent = self()

    tasks =
      for ref <- ["next-a", "next-b"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :roll -> roll(endpoint, ref)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    for task <- tasks, do: send(task.pid, :roll)
    results = Task.await_many(tasks)
    assert [{:ok, rolled}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, :rolled_underneath}] = Enum.filter(results, &match?({:error, _}, &1))
    assert stored(endpoint).legacy_secret_ref == rolled.legacy_secret_ref
  end

  def invalid_overlap(ctx) do
    endpoint = endpoint!(ctx)

    for value <- [-1, 1.5, "60", false, :invalid] do
      assert {:error, :invalid_overlap} = roll(endpoint, "next", overlap_seconds: value)
      assert attributes(stored(endpoint)) == attributes(endpoint)
    end
  end

  def overlap_caps(ctx) do
    resource = configured(ctx, max_overlap_seconds: 120, default_overlap_seconds: 60)
    endpoint = Ash.get!(resource, endpoint!(ctx).id, authorize?: false)
    assert {:error, {:overlap_exceeds_max, 120}} = roll(endpoint, "next", overlap_seconds: 121)
    assert attributes(stored(endpoint)) == attributes(endpoint)
    assert {:ok, rolled} = roll(endpoint, "next", overlap_seconds: 120)
    assert rolled.legacy_previous_secret_retired_at == DateTime.add(@clock, 120)

    for offset <- [120_000_001, 121_000_000] do
      assert {:error, {:overlap_exceeds_max, 120}} =
               Lifecycle.schedule_previous_retirement(
                 rolled,
                 DateTime.add(@clock, offset, :microsecond),
                 slot: :legacy,
                 now: @clock
               )
    end

    assert attributes(stored(rolled)) == attributes(rolled)

    assert {:ok, _} =
             Lifecycle.schedule_previous_retirement(
               rolled,
               DateTime.add(@clock, 120),
               slot: :legacy,
               now: @clock
             )

    for default <- [0, 30] do
      resource = configured(ctx, default_overlap_seconds: default)
      endpoint = Ash.get!(resource, endpoint!(ctx).id, authorize?: false)

      assert {:ok, rolled} =
               Lifecycle.roll_secret(endpoint,
                 slot: :legacy,
                 new_secret_ref: "default",
                 now: @clock
               )

      assert rolled.legacy_previous_secret_retired_at == DateTime.add(@clock, default)
    end
  end

  def undated_previous(ctx) do
    endpoint = endpoint!(ctx, legacy_previous_secret_ref: "legacy-old")

    for caller <- [endpoint, Map.put(endpoint, :legacy_previous_secret_ref, nil)] do
      assert {:error, :previous_secret_undated} = roll(caller, "next")
    end

    assert {:ok, 0} = Lifecycle.expire_previous_secrets(ctx.endpoint, slot: :legacy, now: @clock)
    at = DateTime.add(@clock, 60)

    assert {:ok, scheduled} =
             Lifecycle.schedule_previous_retirement(endpoint, at, slot: :legacy, now: @clock)

    assert {:error, :overlap_active} = roll(scheduled, "next")
    assert {:ok, _} = roll(scheduled, "next", now: at)
    endpoint = endpoint!(ctx, legacy_previous_secret_ref: "legacy-old")
    assert {:ok, expired} = Lifecycle.expire_previous_secret(endpoint, slot: :legacy, now: @clock)
    assert {:ok, _} = roll(expired, "next")
  end

  def scheduling_guards(ctx) do
    endpoint = endpoint!(ctx)

    assert {:error, :no_previous_secret} =
             Lifecycle.schedule_previous_retirement(
               endpoint,
               @clock,
               slot: :legacy,
               now: @clock
             )

    endpoint = endpoint!(ctx, legacy_previous_secret_ref: "legacy-old")

    assert {:error, :invalid_retirement_time} =
             Lifecycle.schedule_previous_retirement(
               endpoint,
               nil,
               slot: :legacy,
               now: @clock
             )

    assert {:error, :retirement_in_past} =
             Lifecycle.schedule_previous_retirement(
               endpoint,
               DateTime.add(@clock, -1),
               slot: :legacy,
               now: @clock
             )

    assert {:ok, scheduled} =
             Lifecycle.schedule_previous_retirement(
               endpoint,
               @clock,
               slot: :legacy,
               now: @clock
             )

    assert scheduled.legacy_previous_secret_retired_at == @clock
    assert {:ok, 1} = Lifecycle.expire_previous_secrets(ctx.endpoint, slot: :legacy, now: @clock)
  end

  def reference_validation(ctx) do
    endpoint =
      endpoint!(ctx,
        previous_secret_ref: "standard-old",
        legacy_previous_secret_ref: "legacy-old"
      )

    for ref <- ["legacy", "legacy-old"] do
      assert {:error, :same_reference} = roll(endpoint, ref)
    end

    for ref <- ["standard", "standard-old"] do
      assert {:error, :same_reference} = Lifecycle.roll_secret(endpoint, new_secret_ref: ref)
    end

    for slot <- [:standard, :legacy], ref <- [nil, "", 1] do
      assert {:error, :new_secret_ref_required} =
               Lifecycle.roll_secret(endpoint, slot: slot, new_secret_ref: ref)
    end

    assert {:ok, expired} = Lifecycle.expire_previous_secret(endpoint, slot: :legacy, now: @clock)
    assert {:ok, rolled} = roll(expired, "standard")
    assert rolled.secret_ref == "standard"
    assert rolled.legacy_secret_ref == "standard"
  end

  def slot_isolation(ctx) do
    endpoint = endpoint!(ctx)
    standard = Map.drop(attributes(endpoint), @fields)
    assert {:ok, legacy} = roll(endpoint, "legacy-next")
    assert Map.drop(attributes(legacy), @fields) == standard
    legacy_fields = Map.take(legacy, @fields)

    assert {:ok, both} =
             Lifecycle.roll_secret(legacy,
               slot: :standard,
               new_secret_ref: "standard-next",
               now: @clock
             )

    assert Map.take(both, @fields) == legacy_fields

    assert {:ok, both} =
             Lifecycle.schedule_previous_retirement(both, @clock, slot: :legacy, now: @clock)

    assert both.previous_secret_ref == "standard"
    assert {:ok, 1} = Lifecycle.expire_previous_secrets(ctx.endpoint, slot: :legacy, now: @clock)
    both = stored(both)
    assert both.previous_secret_ref == "standard"
    legacy_fields = Map.take(both, @fields)
    assert {:ok, both} = Lifecycle.expire_previous_secret(both, now: @clock)
    assert Map.take(both, @fields) == legacy_fields
  end

  def stale_writes(ctx) do
    endpoint = endpoint!(ctx)
    assert {:ok, rolled} = roll(endpoint, "next")
    assert {:ok, expired} = Lifecycle.expire_previous_secret(rolled, slot: :legacy, now: @clock)
    assert {:ok, again} = roll(expired, "third")

    assert {:error, :previous_secret_changed} =
             Lifecycle.schedule_previous_retirement(
               rolled,
               @clock,
               slot: :legacy,
               now: @clock
             )

    assert {:ok, ^rolled} = Lifecycle.expire_previous_secret(rolled, slot: :legacy, now: @clock)
    assert attributes(stored(again)) == attributes(again)
  end

  def disabled_lifecycle(ctx) do
    resource = configured(ctx, legacy_key_lifecycle: :off)
    endpoint = Ash.get!(resource, endpoint!(ctx).id, authorize?: false)
    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} = roll(endpoint, "next")

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             Lifecycle.expire_previous_secret(endpoint, slot: :legacy)

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             Lifecycle.expire_previous_secrets(resource, slot: :legacy)

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             Lifecycle.schedule_previous_retirement(endpoint, @clock, slot: :legacy)
  end

  def retired_signing(ctx) do
    for offset <- [0, 1] do
      {endpoint, session} = receiver_endpoint!(ctx, @clock)
      parent = self()

      resolver = fn ref ->
        send(parent, {:resolved, ref})
        Map.fetch(keys(), ref)
      end

      assert :ok =
               deliver(ctx, endpoint, :legacy,
                 secret_resolver: resolver,
                 now: fn -> DateTime.add(@clock, offset) end
               )

      refute_received {:resolved, "legacy-old"}
      assert_received {:resolved, "legacy"}
      headers = headers!(session)

      assert {:ok, _} =
               AshHooks.Legacy.verify(
                 keys()["legacy"],
                 @body,
                 headers["x-webhook-signature"],
                 System.system_time(:second)
               )

      refute headers["x-webhook-signature"] =~ "v1prev="
      stored = stored(endpoint)
      assert stored.legacy_secret_first_used_at == DateTime.add(@clock, offset)
      assert is_nil(stored.legacy_previous_secret_first_used_at)
      assert is_nil(stored.secret_first_used_at)
      assert stored.legacy_previous_secret_ref == "legacy-old"
    end
  end

  def overlap_signing(ctx) do
    {endpoint, session} = receiver_endpoint!(ctx, DateTime.add(@clock, 1))
    assert :ok = deliver(ctx, endpoint, :dual)
    assert_legacy_signatures(headers!(session), true)
    stored = stored(endpoint)
    assert stored.legacy_secret_first_used_at == @clock
    assert stored.legacy_previous_secret_first_used_at == @clock
    assert stored.secret_first_used_at == @clock
    assert stored.previous_secret_first_used_at == @clock
    later = DateTime.add(@clock, 1)
    assert :ok = deliver(ctx, endpoint, :dual, now: fn -> later end)
    assert stored(endpoint).legacy_secret_first_used_at == @clock
    assert stored(endpoint).legacy_previous_secret_first_used_at == @clock
  end

  def undated_signing(ctx) do
    {endpoint, session} = receiver_endpoint!(ctx, nil)
    assert :ok = deliver(ctx, endpoint, :legacy)
    assert_legacy_signatures(headers!(session), true)
    assert stored(endpoint).legacy_previous_secret_first_used_at == @clock

    assert {:ok, scheduled} =
             Lifecycle.schedule_previous_retirement(endpoint, @clock, slot: :legacy, now: @clock)

    assert :ok = deliver(ctx, scheduled, :legacy)
  end

  def signing_race(ctx) do
    {endpoint, session} = receiver_endpoint!(ctx, DateTime.add(@clock, 60))
    parent = self()

    task =
      Task.async(fn ->
        deliver(ctx, endpoint, :legacy,
          delivery_headers: fn _row, _endpoint, _tenant ->
            send(parent, {:signed, self()})

            receive do
              :continue -> %{}
            end
          end
        )
      end)

    assert_receive {:signed, sender}, 5_000
    assert {:ok, expired} = Lifecycle.expire_previous_secret(endpoint, slot: :legacy, now: @clock)
    assert {:ok, rolled} = roll(expired, "next")
    send(sender, :continue)
    assert :ok = Task.await(task)
    assert_legacy_signatures(headers!(session), true)
    stored = stored(rolled)
    assert stored.legacy_secret_ref == "next"
    assert is_nil(stored.legacy_secret_first_used_at)
    assert is_nil(stored.legacy_previous_secret_first_used_at)
  end

  def signing_modes(ctx) do
    {endpoint, session} = receiver_endpoint!(ctx, DateTime.add(@clock, 60))
    assert :ok = deliver(ctx, endpoint, :standard)
    refute Map.has_key?(headers!(session), "x-webhook-signature")
    assert is_nil(stored(endpoint).legacy_secret_first_used_at)
    assert is_nil(stored(endpoint).legacy_previous_secret_first_used_at)
    {endpoint, session} = receiver_endpoint!(ctx, DateTime.add(@clock, 60))
    assert :ok = deliver(ctx, endpoint, :legacy)
    assert_legacy_signatures(headers!(session), true)
    assert is_nil(stored(endpoint).secret_first_used_at)
    assert is_nil(stored(endpoint).previous_secret_first_used_at)
  end

  def zero_overlap_signing(ctx) do
    {endpoint, session} = receiver_endpoint!(ctx, @clock)
    assert {:ok, rolled} = roll(endpoint, "next", overlap_seconds: 0)
    assert :ok = deliver(ctx, rolled, :legacy)
    headers = headers!(session)

    assert {:ok, _} =
             AshHooks.Legacy.verify(
               keys()["next"],
               @body,
               headers["x-webhook-signature"],
               System.system_time(:second)
             )

    refute headers["x-webhook-signature"] =~ "v1prev="
    assert is_nil(stored(endpoint).legacy_previous_secret_first_used_at)
  end

  defp endpoint!(ctx, attrs \\ []) do
    params =
      Map.merge(
        %{
          url: "https://hooks.example.test/lifecycle",
          secret_ref: "standard",
          legacy_secret_ref: "legacy"
        },
        Map.new(attrs)
      )

    Ash.create!(ctx.endpoint, params, authorize?: false)
  end

  defp attributes(endpoint) do
    names = Enum.map(ResourceInfo.attributes(endpoint.__struct__), & &1.name)
    Map.take(endpoint, names)
  end

  defp stored(endpoint), do: Ash.get!(endpoint.__struct__, endpoint.id, authorize?: false)

  defp roll(endpoint, ref, opts \\ []) do
    Lifecycle.roll_secret(
      endpoint,
      Keyword.merge(
        [slot: :legacy, new_secret_ref: ref, overlap_seconds: 60, now: @clock],
        opts
      )
    )
  end

  defp configured(ctx, opts) do
    module = Module.concat(ctx.endpoint, "Configured#{System.unique_integer([:positive])}")
    domain = Module.concat(module, Domain)

    Code.compile_quoted(
      quote do
        unquote(
          endpoint_definition(
            module,
            domain,
            ctx.layer,
            ctx.repo,
            ctx.storage,
            ctx.endpoint_table,
            Keyword.merge([legacy_key_lifecycle: :on], opts)
          )
        )

        unquote(domain_definition(domain, [module]))
      end
    )

    on_exit(fn -> purge([module, domain]) end)
    module
  end

  defp endpoint_definition(module, domain, layer, repo, storage, table, opts) do
    options = Enum.map(opts, fn {key, value} -> {key, [], [value]} end)
    block = storage_block(storage, table, repo)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use Ash.Resource,
          domain: unquote(domain),
          data_layer: unquote(layer),
          extensions: [AshHooks.Endpoint]

        unquote(block)

        actions do
          defaults([:read, :create, :update])
          default_accept(:*)
        end

        endpoint do
          key_lifecycle(:on)
          unquote_splicing(options)
        end
      end
    end
  end

  defp delivery_definition(module, domain, layer, repo, storage, table) do
    block = storage_block(storage, table, repo)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use Ash.Resource,
          domain: unquote(domain),
          data_layer: unquote(layer),
          extensions: [AshHooks.OutboundDelivery]

        unquote(block)

        attributes do
          timestamps()
        end

        actions do
          defaults([:read])
        end
      end
    end
  end

  defp domain_definition(module, resources) do
    declarations = Enum.map(resources, fn resource -> {:resource, [], [resource]} end)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

        resources do
          (unquote_splicing(declarations))
        end
      end
    end
  end

  defp storage_block(storage, table, repo) do
    block =
      quote do
        table(unquote(table))
        repo(unquote(repo))
      end

    {storage, [], [[do: block]]}
  end

  defp create_tables(repo, storage, endpoints, deliveries) do
    {id, time, bytes, map} =
      if storage == :postgres,
        do: {"UUID", "TIMESTAMP(6)", "BYTEA", "JSONB"},
        else: {"TEXT", "TEXT", "BLOB", "TEXT"}

    repo.query!("""
    CREATE TABLE #{endpoints} (
      id #{id} PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT,
      secret_created_at #{time}, secret_first_used_at #{time}, secret_retired_at #{time},
      previous_secret_created_at #{time}, previous_secret_first_used_at #{time},
      previous_secret_retired_at #{time}, legacy_secret_created_at #{time},
      legacy_secret_first_used_at #{time}, legacy_previous_secret_created_at #{time},
      legacy_previous_secret_first_used_at #{time}, legacy_previous_secret_retired_at #{time}
    )
    """)

    on_exit(fn -> repo.query!("DROP TABLE #{endpoints}") end)

    repo.query!("""
    CREATE TABLE #{deliveries} (
      id #{id} PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      payload #{bytes} NOT NULL, endpoint_id #{id} NOT NULL, subscription_id #{id},
      signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
      response_status INTEGER, response_snippet TEXT, last_error TEXT, next_attempt_at #{time},
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound', attempt_token #{id},
      send_lease_expires_at #{time}, enqueue_token #{id}, enqueue_lease_expires_at #{time},
      endpoint_snapshot #{map}, inserted_at #{time} NOT NULL, updated_at #{time} NOT NULL
    )
    """)

    on_exit(fn -> repo.query!("DROP TABLE #{deliveries}") end)

    repo.query!(
      "CREATE UNIQUE INDEX #{deliveries}_unique_delivery_index ON #{deliveries} (endpoint_id, event_uuid)"
    )
  end

  defp purge(modules) do
    for module <- modules do
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp receiver_endpoint!(ctx, at) do
    {:ok, %{status: status, body: body}} =
      Bounded.request(
        :post,
        receiver_root() <> "/api/session",
        %{"content-type" => "application/json"},
        Jason.encode!(%{status_code: 200}),
        validate_destination: false,
        max_body_bytes: 65_536
      )

    assert status in 200..299
    session = Jason.decode!(body)["uuid"]

    on_exit(fn ->
      {:ok, %{status: status}} =
        Bounded.request(:delete, receiver_root() <> "/api/session/" <> session, %{}, "",
          validate_destination: false
        )

      assert status in 200..299
    end)

    endpoint =
      endpoint!(ctx,
        url: receiver_root() <> "/" <> session,
        previous_secret_ref: "standard-old",
        legacy_previous_secret_ref: "legacy-old"
      )

    endpoint =
      endpoint
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:legacy_previous_secret_retired_at, at)
      |> Ash.Changeset.force_change_attribute(
        :previous_secret_retired_at,
        DateTime.add(@clock, 60)
      )
      |> Ash.update!(authorize?: false)

    {endpoint, session}
  end

  defp deliver(ctx, endpoint, mode, opts \\ []) do
    row =
      Ash.create!(
        ctx.delivery,
        %{
          event_uuid: "msg_" <> Ash.UUID.generate(),
          event_type: "rotation",
          signing_mode: mode,
          payload: @body,
          endpoint_id: endpoint.id
        },
        action: :dispatch,
        authorize?: false
      )

    config = [
      deliveries: ctx.delivery,
      endpoints: ctx.endpoint,
      secret_resolver: fn ref -> Map.fetch(keys(), ref) end,
      now: fn -> @clock end,
      destination_policy: fn _url, _ctx -> :allow end,
      http_opts: [validate_destination: false]
    ]

    AshHooks.Delivery.run(
      %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
      Keyword.merge(config, opts)
    )
  end

  defp keys do
    %{
      "standard" => "whsec_" <> Base.encode64(:binary.copy(<<1>>, 32)),
      "standard-old" => "whsec_" <> Base.encode64(:binary.copy(<<2>>, 32)),
      "legacy" => :binary.copy(<<3>>, 32),
      "legacy-old" => :binary.copy(<<4>>, 32),
      "next" => :binary.copy(<<5>>, 32)
    }
  end

  defp headers!(session) do
    {:ok, %{status: 200, body: body}} =
      Bounded.request(:get, receiver_root() <> "/api/session/" <> session <> "/requests", %{}, "",
        validate_destination: false,
        max_body_bytes: 1_048_576
      )

    [request] = Jason.decode!(body)
    assert Base.decode64!(request["request_payload_base64"]) == @body
    Map.new(request["headers"], &{String.downcase(&1["name"]), &1["value"]})
  end

  defp assert_legacy_signatures(headers, previous?) do
    signature = headers["x-webhook-signature"]

    assert {:ok, _} =
             AshHooks.Legacy.verify(
               keys()["legacy"],
               @body,
               signature,
               System.system_time(:second)
             )

    assert String.contains?(signature, "v1prev=") == previous?
    previous = String.replace(signature, ~r/,v1=[^,]+/, "") |> String.replace("v1prev=", "v1=")

    assert {:ok, _} =
             AshHooks.Legacy.verify(
               keys()["legacy-old"],
               @body,
               previous,
               System.system_time(:second)
             )
  end

  defp receiver_root,
    do: "http://localhost:" <> System.get_env("ASH_HOOKS_REAL_RECEIVER_PORT", "52871")
end
