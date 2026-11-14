defmodule AshHooks.Test.PreviousKeyRetirementCases do
  @moduledoc false

  defmacro __using__(opts) do
    layer = opts |> Keyword.fetch!(:data_layer) |> Macro.expand(__CALLER__)
    repo = opts |> Keyword.fetch!(:repo) |> Macro.expand(__CALLER__)
    prefix = Keyword.fetch!(opts, :prefix)
    domain = Module.concat(__CALLER__.module, Domain)
    endpoint = Module.concat(__CALLER__.module, Endpoint)
    delivery = Module.concat(__CALLER__.module, Delivery)
    storage = if layer == AshPostgres.DataLayer, do: :postgres, else: :sqlite
    endpoint_storage = storage(storage, prefix <> "_endpoints", repo)
    delivery_storage = storage(storage, prefix <> "_deliveries", repo)

    # Emit the same resource fixtures and ExUnit cases for both real data layers.
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      use ExUnit.Case, async: false
      @moduletag unquote(if storage == :postgres, do: [postgres: true], else: [])

      defmodule Endpoint do
        @moduledoc false
        use Ash.Resource,
          domain: unquote(domain),
          data_layer: unquote(layer),
          extensions: [AshHooks.Endpoint]

        unquote(endpoint_storage)

        actions do
          defaults([:read, :create, :update])
          default_accept(:*)
        end

        endpoint do
          key_lifecycle(:on)
        end
      end

      defmodule Delivery do
        @moduledoc false
        use Ash.Resource,
          domain: unquote(domain),
          data_layer: unquote(layer),
          extensions: [AshHooks.OutboundDelivery]

        unquote(delivery_storage)

        attributes do
          timestamps()
        end

        actions do
          defaults([:read])
        end
      end

      defmodule Domain do
        @moduledoc false
        use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

        resources do
          resource(unquote(endpoint))
          resource(unquote(delivery))
        end
      end

      alias AshHooks.Delivery, as: Runtime
      alias AshHooks.Endpoint, as: Lifecycle
      alias AshHooks.Http.Bounded
      alias unquote(repo), as: Repo

      @endpoints unquote(prefix <> "_endpoints")
      @deliveries unquote(prefix <> "_deliveries")
      @postgres unquote(storage == :postgres)
      @clock ~U[2026-11-13 12:00:00.000000Z]
      @body ~s({"event":"retirement"})

      setup_all do
        id_type = if @postgres, do: "UUID", else: "TEXT"
        time_type = if @postgres, do: "TIMESTAMP(6)", else: "TEXT"
        bytes_type = if @postgres, do: "BYTEA", else: "BLOB"
        map_type = if @postgres, do: "JSONB", else: "TEXT"

        Repo.query!("""
        CREATE TABLE #{@endpoints} (
          id #{id_type} PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
          secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
          legacy_previous_secret_ref TEXT,
          secret_created_at #{time_type}, secret_first_used_at #{time_type},
          secret_retired_at #{time_type}, previous_secret_created_at #{time_type},
          previous_secret_first_used_at #{time_type}, previous_secret_retired_at #{time_type}
        )
        """)

        on_exit(fn -> Repo.query!("DROP TABLE #{@endpoints}") end)

        Repo.query!("""
        CREATE TABLE #{@deliveries} (
          id #{id_type} PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
          payload #{bytes_type} NOT NULL, endpoint_id #{id_type} NOT NULL, subscription_id #{id_type},
          signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
          attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
          response_snippet TEXT, last_error TEXT, next_attempt_at #{time_type},
          dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
          dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
          attempt_token #{id_type}, send_lease_expires_at #{time_type},
          enqueue_token #{id_type}, enqueue_lease_expires_at #{time_type}, endpoint_snapshot #{map_type},
          inserted_at #{time_type} NOT NULL, updated_at #{time_type} NOT NULL
        )
        """)

        on_exit(fn -> Repo.query!("DROP TABLE #{@deliveries}") end)

        Repo.query!("""
        CREATE UNIQUE INDEX #{@deliveries}_unique_delivery_index
        ON #{@deliveries} (endpoint_id, event_uuid)
        """)

        :ok
      end

      setup do
        Repo.query!("DELETE FROM #{@deliveries}")
        Repo.query!("DELETE FROM #{@endpoints}")
        :ok
      end

      @tag :real_receiver
      test "at and after retirement only the current signature reaches the receiver before a sweep" do
        for offset <- [0, 1] do
          {endpoint, session} = endpoint!(@clock)
          keys = keys()
          row = delivery!(endpoint)
          assert :ok = deliver(row, keys, now: fn -> DateTime.add(@clock, offset) end)
          headers = received_headers!(session, row)
          assert [_signature] = String.split(headers["webhook-signature"], " ")
          assert {:ok, _} = AshHooks.Signing.verify(@body, headers, keys["current"])

          assert {:error, :invalid_signature} =
                   AshHooks.Signing.verify(@body, headers, keys["previous"])

          stored = Ash.get!(Endpoint, endpoint.id, authorize?: false)
          assert stored.previous_secret_ref == "previous"
        end
      end

      @tag :real_receiver
      test "a retired ref is never resolved even when the host refuses it" do
        {endpoint, session} = endpoint!(@clock)
        row = delivery!(endpoint)
        key = keys()["current"]
        parent = self()

        resolver = fn
          "current" ->
            {:ok, key}

          "previous" ->
            send(parent, :retired_ref_resolved)
            {:error, :retired}
        end

        assert :ok = deliver(row, %{}, secret_resolver: resolver)
        refute_received :retired_ref_resolved
        assert [_] = String.split(received_headers!(session, row)["webhook-signature"], " ")
        assert Ash.get!(Delivery, row.id, authorize?: false).status == :succeeded
      end

      @tag :real_receiver
      test "a retired previous key is not first-use stamped by a delivery" do
        {endpoint, _session} = endpoint!(@clock)
        assert :ok = deliver(delivery!(endpoint), keys())
        stored = Ash.get!(Endpoint, endpoint.id, authorize?: false)
        assert stored.secret_first_used_at == @clock
        assert is_nil(stored.previous_secret_first_used_at)
      end

      @tag :real_receiver
      test "before retirement both keys sign and receive first-use stamps" do
        {endpoint, session} = endpoint!(DateTime.add(@clock, 1))
        row = delivery!(endpoint)
        keys = keys()
        assert :ok = deliver(row, keys)
        headers = received_headers!(session, row)
        assert [_, _] = String.split(headers["webhook-signature"], " ")

        for key <- Map.values(keys),
            do: assert({:ok, _} = AshHooks.Signing.verify(@body, headers, key))

        stored = Ash.get!(Endpoint, endpoint.id, authorize?: false)
        assert stored.secret_first_used_at == @clock
        assert stored.previous_secret_first_used_at == @clock
      end

      @tag :real_receiver
      test "a roll between signing and stamping never stamps replacement refs" do
        {endpoint, session} = endpoint!(DateTime.add(@clock, 60))
        row = delivery!(endpoint)
        parent = self()

        task =
          Task.async(fn ->
            deliver(row, keys(),
              delivery_headers: fn _row, _endpoint, _tenant ->
                send(parent, {:signed, self()})

                receive do
                  :continue_stamping -> %{}
                after
                  5_000 -> raise "signing barrier was not released"
                end
              end
            )
          end)

        assert_receive {:signed, sender}, 5_000

        assert {:ok, rolled} =
                 Lifecycle.roll_secret(endpoint, new_secret_ref: "replacement", now: @clock)

        send(sender, :continue_stamping)
        assert :ok = Task.await(task)
        assert [_, _] = String.split(received_headers!(session, row)["webhook-signature"], " ")
        stored = Ash.get!(Endpoint, endpoint.id, authorize?: false)
        assert stored.secret_ref == rolled.secret_ref
        assert stored.previous_secret_ref == "current"
        assert is_nil(stored.secret_first_used_at)
        assert is_nil(stored.previous_secret_first_used_at)
      end

      @tag :real_receiver
      test "undated previous signs until its scheduled retirement" do
        {endpoint, session} = endpoint!(nil)
        first = delivery!(endpoint)
        assert :ok = deliver(first, keys())
        assert [_, _] = String.split(received_headers!(session, first)["webhook-signature"], " ")
        at = DateTime.add(@clock, 60)

        assert {:ok, scheduled} =
                 Lifecycle.schedule_previous_retirement(endpoint, at, now: @clock)

        assert scheduled.previous_secret_ref == "previous"
        assert scheduled.previous_secret_retired_at == at
        second = delivery!(endpoint)
        assert :ok = deliver(second, keys(), now: fn -> at end)
        assert [_] = String.split(received_headers!(session, second)["webhook-signature"], " ")
      end

      test "undated previous refuses rolling including a stale caller" do
        endpoint = lifecycle_endpoint!(nil)

        assert {:error, :previous_secret_undated} =
                 Lifecycle.roll_secret(endpoint, new_secret_ref: "next", now: @clock)

        assert {:error, :previous_secret_undated} =
                 Lifecycle.roll_secret(%{endpoint | previous_secret_ref: nil},
                   new_secret_ref: "next",
                   now: @clock
                 )

        assert Ash.get!(Endpoint, endpoint.id, authorize?: false).secret_ref == "current"
      end

      test "the sweep skips undated previous and immediate expiration resolves it" do
        endpoint = lifecycle_endpoint!(nil)
        assert {:ok, 0} = Lifecycle.expire_previous_secrets(Endpoint, now: @clock)

        assert Ash.get!(Endpoint, endpoint.id, authorize?: false).previous_secret_ref ==
                 "previous"

        assert {:ok, expired} = Lifecycle.expire_previous_secret(endpoint, now: @clock)
        assert is_nil(expired.previous_secret_ref)
        assert expired.previous_secret_retired_at == @clock
      end

      test "scheduling refuses a past time or an absent previous ref and accepts now" do
        endpoint = lifecycle_endpoint!(nil)

        assert {:error, :retirement_in_past} =
                 Lifecycle.schedule_previous_retirement(endpoint, DateTime.add(@clock, -1),
                   now: @clock
                 )

        assert {:ok, scheduled} =
                 Lifecycle.schedule_previous_retirement(endpoint, @clock, now: @clock)

        assert scheduled.previous_secret_retired_at == @clock
        assert {:ok, expired} = Lifecycle.expire_previous_secret(scheduled, now: @clock)

        assert {:error, :no_previous_secret} =
                 Lifecycle.schedule_previous_retirement(expired, @clock, now: @clock)
      end

      test "scheduling refuses invalid times and a replaced previous reference" do
        endpoint = lifecycle_endpoint!(nil)

        assert {:error, :invalid_retirement_time} =
                 Lifecycle.schedule_previous_retirement(endpoint, nil, now: @clock)

        replaced =
          endpoint
          |> Ash.Changeset.for_update(:update, %{previous_secret_ref: "replacement"})
          |> Ash.update!(authorize?: false)

        assert {:error, :previous_secret_changed} =
                 Lifecycle.schedule_previous_retirement(endpoint, @clock, now: @clock)

        stored = Ash.get!(Endpoint, endpoint.id, authorize?: false)
        assert stored.previous_secret_ref == replaced.previous_secret_ref
        assert is_nil(stored.previous_secret_retired_at)
      end

      test "scheduling defaults to the current UTC clock" do
        endpoint = lifecycle_endpoint!(nil)
        at = DateTime.add(DateTime.utc_now(), 3_600)
        assert {:ok, scheduled} = Lifecycle.schedule_previous_retirement(endpoint, at)
        assert scheduled.previous_secret_retired_at == at
      end

      @tag :real_receiver
      test "legacy-only deliveries never stamp standard keys that did not sign" do
        {endpoint, session} = endpoint!(DateTime.add(@clock, 60))

        endpoint =
          endpoint
          |> Ash.Changeset.for_update(:update, %{legacy_secret_ref: "legacy"})
          |> Ash.update!(authorize?: false)

        keys = Map.put(keys(), "legacy", :crypto.strong_rand_bytes(32))
        row = delivery!(endpoint, :legacy)
        assert :ok = deliver(row, keys)

        # Legacy sends have no Standard Webhooks id header to select on.
        [request] = received_requests!(session)
        headers = request_headers(request)
        refute Map.has_key?(headers, "webhook-signature")

        assert {:ok, _} =
                 AshHooks.Legacy.verify(
                   keys["legacy"],
                   @body,
                   headers["x-webhook-signature"],
                   System.system_time(:second)
                 )

        stored = Ash.get!(Endpoint, endpoint.id, authorize?: false)
        assert is_nil(stored.secret_first_used_at)
        assert is_nil(stored.previous_secret_first_used_at)
      end

      defp keys do
        Map.new(["current", "previous"], fn ref ->
          {ref, "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))}
        end)
      end

      defp lifecycle_endpoint!(retired_at, url \\ "https://hooks.example.test/retirement") do
        Endpoint
        |> Ash.Changeset.for_create(:create, %{
          url: url,
          secret_ref: "current",
          previous_secret_ref: "previous"
        })
        |> Ash.Changeset.force_change_attribute(:previous_secret_retired_at, retired_at)
        |> Ash.create!(authorize?: false)
      end

      defp receiver_root do
        "http://localhost:" <> System.get_env("ASH_HOOKS_REAL_RECEIVER_PORT", "52871")
      end

      defp endpoint!(retired_at) do
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

        {lifecycle_endpoint!(retired_at, receiver_root() <> "/" <> session), session}
      end

      defp delivery!(endpoint, mode \\ :standard) do
        Ash.create!(
          Delivery,
          %{
            event_uuid: "msg_" <> Ash.UUID.generate(),
            event_type: "retirement",
            signing_mode: mode,
            payload: @body,
            endpoint_id: endpoint.id
          },
          action: :dispatch,
          authorize?: false
        )
      end

      defp deliver(row, keys, opts \\ []) do
        config = [
          deliveries: Delivery,
          endpoints: Endpoint,
          secret_resolver: fn ref -> Map.fetch(keys, ref) end,
          now: fn -> @clock end,
          destination_policy: fn _url, _ctx -> :allow end,
          http_opts: [validate_destination: false]
        ]

        Runtime.run(
          %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
          Keyword.merge(config, opts)
        )
      end

      defp received_headers!(session, row) do
        [headers] =
          for request <- received_requests!(session),
              headers = request_headers(request),
              headers["webhook-id"] == row.event_uuid,
              do: headers

        headers
      end

      defp request_headers(request) do
        Map.new(request["headers"], &{String.downcase(&1["name"]), &1["value"]})
      end

      defp received_requests!(session) do
        {:ok, %{status: 200, body: body}} =
          Bounded.request(
            :get,
            receiver_root() <> "/api/session/" <> session <> "/requests",
            %{},
            "",
            validate_destination: false,
            max_body_bytes: 1_048_576
          )

        Jason.decode!(body)
      end
    end
  end

  defp storage(layer, table, repo) do
    block =
      quote do
        table(unquote(table))
        repo(unquote(repo))
      end

    {layer, [], [[do: block]]}
  end
end
