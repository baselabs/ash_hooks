defmodule AshHooks.SecretRollingTest do
  @moduledoc """
  Secret rolling with an overlap window: rolling moves the incumbent
  reference to previous_secret_ref (the multi-signature seam Standard
  Webhooks specifies — both keys sign until the overlap ends), schedules
  the old key's retirement, and records each key's created / first-used /
  retired times — never secret material. The scheduled sweep retires the
  old key on time; an immediate retirement is one call. A real loopback
  receiver proves BOTH signatures arrive on the wire during overlap.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SecretRollingTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("secret_rolling_endpoints")
      repo(AshHooks.Test.Repo)
    end

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
      domain: AshHooks.SecretRollingTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("secret_rolling_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end
  end

  defmodule PlainEndpoint do
    @moduledoc false
    # no key_lifecycle declaration: the lifecycle columns are NOT injected
    use Ash.Resource,
      domain: AshHooks.SecretRollingTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("secret_rolling_plain_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.SecretRollingTest.Endpoint)
      resource(AshHooks.SecretRollingTest.PlainEndpoint)
      resource(AshHooks.SecretRollingTest.Delivery)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.Test.Repo

  @endpoints "secret_rolling_endpoints"
  @deliveries "secret_rolling_deliveries"
  @payload Jason.encode!(%{"order" => 1})
  @current "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
  @fresh "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))
  @later "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT,
      secret_created_at TEXT, secret_first_used_at TEXT, secret_retired_at TEXT,
      previous_secret_created_at TEXT, previous_secret_first_used_at TEXT,
      previous_secret_retired_at TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
      signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
      response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS secret_rolling_plain_endpoints (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS secret_rolling_plain_endpoints")
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM secret_rolling_plain_endpoints")
    :ok
  end

  defp secret_ref do
    ("sr-" <> Ash.UUID.generate()) |> String.slice(0, 13)
  end

  # a real loopback receiver capturing the exact request bytes + headers
  defp receiver_endpoint!(parent) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      case :gen_tcp.accept(listen, 10_000) do
        {:ok, socket} ->
          {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
          send(parent, {:rolling_request, request})

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\": true}"
            )

          :gen_tcp.close(socket)

        _closed ->
          :ok
      end

      :gen_tcp.close(listen)
    end)

    id = Ash.UUID.generate()
    ref = secret_ref()

    Repo.query!(
      "INSERT INTO #{@endpoints} (id, url, status, secret_ref, secret_created_at) VALUES (?, ?, 'enabled', ?, ?)",
      [id, "http://127.0.0.1:#{port}/hook", ref, DateTime.to_iso8601(DateTime.utc_now())]
    )

    {Ash.get!(Endpoint, id, authorize?: false), ref}
  end

  defp resolver(map) do
    fn ref ->
      case Map.fetch(map, ref) do
        {:ok, secret} -> {:ok, secret}
        :error -> {:error, :unknown_ref}
      end
    end
  end

  test "rolling moves the incumbent to previous and schedules its retirement" do
    {endpoint, ref} = receiver_endpoint!(self())
    now = DateTime.utc_now()

    assert {:ok, rolled} =
             AshHooks.Endpoint.roll_secret(endpoint,
               new_secret_ref: "ref-new",
               overlap_seconds: 3_600,
               now: now
             )

    assert rolled.secret_ref == "ref-new"
    assert rolled.previous_secret_ref == ref
    assert rolled.secret_created_at == DateTime.truncate(now, :microsecond)
    assert rolled.secret_first_used_at == nil
    assert rolled.previous_secret_created_at != nil
    # the scheduled retirement of the OLD key
    assert rolled.previous_secret_retired_at ==
             DateTime.add(DateTime.truncate(now, :microsecond), 3_600, :second)

    # no secret material anywhere on the row
    for {_, value} <- Map.take(rolled, [:secret_ref, :previous_secret_ref]),
        do: refute(String.starts_with?(value || "", "whsec_"))
  end

  test "an overlap delivery carries BOTH signatures on the wire and marks first use" do
    {endpoint, ref} = receiver_endpoint!(self())
    current_ref = ref

    secrets = %{current_ref => @current, "ref-rotated" => @fresh}
    old = %{current_ref => @current}
    both = Map.merge(old, %{"ref-rotated" => @fresh})

    now = DateTime.utc_now()

    assert {:ok, _} =
             AshHooks.Endpoint.roll_secret(endpoint,
               new_secret_ref: "ref-rotated",
               overlap_seconds: 3_600,
               now: now
             )

    {:ok, event} = AshHooks.Event.new(type: :order_paid, payload: @payload)

    row =
      Ash.create!(
        Delivery,
        %{
          event_uuid: event.id,
          event_type: "order_paid",
          payload: @payload,
          endpoint_id: endpoint.id
        },
        action: :dispatch,
        authorize?: false
      )

    run_result =
      DeliveryRuntime.run(
        %{"endpoint_id" => endpoint.id, "event_uuid" => row.event_uuid},
        deliveries: Delivery,
        endpoints: Endpoint,
        secret_resolver: resolver(both),
        destination_policy: fn _url, _ctx -> :allow end,
        http_opts: [validate_destination: false]
      )

    IO.inspect(run_result, label: "RUN")

    IO.inspect(Repo.query!("SELECT status, last_error, response_status FROM #{@deliveries}").rows,
      label: "ROW"
    )

    assert :ok = run_result

    # the real receiver saw one POST whose webhook-signature carries BOTH v1
    assert_receive {:rolling_request, request}

    [signature_header] =
      Regex.scan(~r/webhook-signature: (v1,[^\r\n]+)/, request) |> Enum.map(&Enum.at(&1, 1))

    signatures = String.split(signature_header, " ")
    assert length(signatures) == 2
    assert Enum.all?(signatures, &String.starts_with?(&1, "v1,"))

    # both are valid over the exact bytes: verify each against its key
    {:ok, %{id: id}} = AshHooks.Signing.verify(@payload, extract_headers(request), @fresh)
    assert id == event.id
    {:ok, %{id: id2}} = AshHooks.Signing.verify(@payload, extract_headers(request), @current)
    assert id2 == event.id

    # first-use times recorded for BOTH keys — created/retired untouched
    used = Ash.get!(Endpoint, endpoint.id, authorize?: false)
    assert used.secret_first_used_at != nil
    assert used.previous_secret_first_used_at != nil
    assert used.previous_secret_retired_at != nil
  end

  test "the scheduled sweep retires the old key only when its window ends" do
    {endpoint, ref} = receiver_endpoint!(self())

    now = DateTime.utc_now()

    assert {:ok, _} =
             AshHooks.Endpoint.roll_secret(endpoint,
               new_secret_ref: "ref-next",
               overlap_seconds: 3_600,
               now: now
             )

    # before the window ends: nothing retires
    assert {:ok, 0} =
             AshHooks.Endpoint.expire_previous_secrets(Endpoint,
               now: DateTime.add(now, 3_599, :second)
             )

    still = Ash.get!(Endpoint, endpoint.id, authorize?: false)
    assert still.previous_secret_ref == ref

    # at/after the window: the old key is gone, its retirement stands
    assert {:ok, 1} =
             AshHooks.Endpoint.expire_previous_secrets(Endpoint,
               now: DateTime.add(now, 3_600, :second)
             )

    expired = Ash.get!(Endpoint, endpoint.id, authorize?: false)
    assert expired.previous_secret_ref == nil
    assert expired.previous_secret_retired_at != nil
    assert expired.previous_secret_first_used_at == nil
  end

  test "an immediate retirement expires the old key at once" do
    {endpoint, ref} = receiver_endpoint!(self())

    assert {:ok, rolled} =
             AshHooks.Endpoint.roll_secret(endpoint,
               new_secret_ref: "ref-now",
               overlap_seconds: 3_600
             )

    assert rolled.previous_secret_ref == ref

    assert {:ok, retired} = AshHooks.Endpoint.expire_previous_secret(rolled)
    assert retired.previous_secret_ref == nil
    assert retired.previous_secret_retired_at != nil

    # expiring again is a no-op returning the row
    assert {:ok, again} = AshHooks.Endpoint.expire_previous_secret(retired)
    assert again.previous_secret_ref == nil
  end

  test "rolling requires the lifecycle columns and a fresh reference" do
    {endpoint, ref} = receiver_endpoint!(self())

    assert {:error, :same_reference} =
             AshHooks.Endpoint.roll_secret(endpoint, new_secret_ref: ref)

    assert {:error, :new_secret_ref_required} =
             AshHooks.Endpoint.roll_secret(endpoint, new_secret_ref: "")

    # a plain endpoint (no key_lifecycle :on) fails with the named error
    plain =
      Ash.create!(
        PlainEndpoint,
        %{url: "https://hooks.example.test/accept", secret_ref: "plain-ref"},
        authorize?: false
      )

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{error: error}} =
             AshHooks.Endpoint.roll_secret(plain, new_secret_ref: "other")

    assert error =~ "key_lifecycle"

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             AshHooks.Endpoint.expire_previous_secret(plain)

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             AshHooks.Endpoint.expire_previous_secrets(PlainEndpoint)
  end

  test "the gated writes fence concurrent moves and surface storage faults" do
    {endpoint, _ref} = receiver_endpoint!(self())

    # a concurrent roll moved the incumbent first: the stale struct's
    # gated update matches nothing
    {:ok, _} =
      AshHooks.Endpoint.roll_secret(endpoint, new_secret_ref: "ref-first", overlap_seconds: 60)

    assert {:error, :rolled_underneath} =
             AshHooks.Endpoint.roll_secret(endpoint,
               new_secret_ref: "ref-second",
               overlap_seconds: 60
             )

    # a storage fault on the roll is surfaced, never swallowed
    moved = Ash.get!(Endpoint, endpoint.id, authorize?: false)

    Repo.query!("""
    CREATE TRIGGER roll_abort
    BEFORE UPDATE OF previous_secret_ref ON #{@endpoints}
    BEGIN
      SELECT RAISE(ABORT, 'forced roll rejection');
    END
    """)

    on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS roll_abort") end)

    assert {:error, %Ash.Error.Unknown{}} =
             AshHooks.Endpoint.roll_secret(moved,
               new_secret_ref: "ref-third",
               overlap_seconds: 60
             )

    # the single-row retire paths fence the same way
    with_previous = Ash.get!(Endpoint, endpoint.id, authorize?: false)

    assert {:ok, _no_previous} =
             AshHooks.Endpoint.expire_previous_secret(%{with_previous | previous_secret_ref: nil})

    Repo.query!("DROP TRIGGER IF EXISTS roll_abort")

    {:ok, rolled} =
      AshHooks.Endpoint.roll_secret(with_previous,
        new_secret_ref: "ref-fourth",
        overlap_seconds: 60
      )

    Repo.query!("""
    CREATE TRIGGER retire_abort
    BEFORE UPDATE OF previous_secret_ref ON #{@endpoints}
    BEGIN
      SELECT RAISE(ABORT, 'forced retire rejection');
    END
    """)

    assert {:error, %Ash.Error.Unknown{}} = AshHooks.Endpoint.expire_previous_secret(rolled)

    # and the sweep surfaces its storage faults too
    Repo.query!("UPDATE #{@endpoints} SET previous_secret_retired_at = '2020-01-01T00:00:00Z'")

    assert {:error, %Ash.Error.Unknown{}} = AshHooks.Endpoint.expire_previous_secrets(Endpoint)
  after
    Repo.query!("DROP TRIGGER IF EXISTS roll_abort")
    Repo.query!("DROP TRIGGER IF EXISTS retire_abort")
  end

  test "the default clock arm and the retire race" do
    {endpoint, _ref} = receiver_endpoint!(self())

    # the no-opts calls use the defaults (the \\ [] arm names the ref error)
    assert {:error, :new_secret_ref_required} = AshHooks.Endpoint.roll_secret(endpoint)
    assert {:ok, _} = AshHooks.Endpoint.roll_secret(endpoint, new_secret_ref: "ref-default")

    # a stale struct whose previous key was retired underneath it: the
    # gated retire matches nothing and the row is returned unchanged
    stale = Ash.get!(Endpoint, endpoint.id, authorize?: false)
    {:ok, retired} = AshHooks.Endpoint.expire_previous_secret(stale)

    assert {:ok, again} = AshHooks.Endpoint.expire_previous_secret(stale)
    # the raced retire returns the stale row unchanged (the durable row
    # is the record: retired.previous_secret_ref is nil)
    assert again == stale
    assert retired.previous_secret_ref == nil
  end

  test "rolling emits telemetry with ids, never secret material" do
    test_pid = self()

    :telemetry.attach_many(
      "secret-rolling-test",
      [[:ash_hooks, :endpoint, :roll]],
      fn event, _m, metadata, _c -> send(test_pid, {event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("secret-rolling-test") end)

    {endpoint, _ref} = receiver_endpoint!(self())

    assert {:ok, _} =
             AshHooks.Endpoint.roll_secret(endpoint,
               new_secret_ref: "ref-tel",
               overlap_seconds: 60
             )

    assert_receive {[:ash_hooks, :endpoint, :roll], %{endpoint_id: _id}}
  end

  defp extract_headers(request) do
    request
    |> String.split("\r\n\r\n", parts: 2)
    |> hd()
    |> String.split("\r\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(fn line ->
      [name, value] = String.split(line, ":", parts: 2)
      {String.downcase(String.trim(name)), String.trim(value)}
    end)
    |> Map.new()
  end
end
