defmodule AshHooks.Test.AnswerCustodian do
  @moduledoc false
  @behaviour AshHooks.Custody

  def configure(custodian, answer, sink) do
    Application.put_env(:ash_hooks, __MODULE__, {custodian, answer, sink})
  end

  def clear, do: Application.delete_env(:ash_hooks, __MODULE__)

  def store(ref, material, tenant, kind) do
    {custodian, _, _} = config()
    custodian.store(ref, material, tenant, kind)
  end

  def sign(ref, tenant, kind, input) do
    {custodian, answer, sink} = config()
    send(sink, {:custody_sign, ref, tenant, kind})
    result = custodian.sign(ref, tenant, kind, input)
    if answer == :real, do: result, else: answer
  end

  def verify(ref, tenant, kind, input, signature) do
    {custodian, answer, sink} = config()
    send(sink, {:custody_verify, ref, tenant, kind})
    result = custodian.verify(ref, tenant, kind, input, signature)
    if answer == :real, do: result, else: answer
  end

  def public_key(ref, tenant, kind) do
    {custodian, _, _} = config()
    custodian.public_key(ref, tenant, kind)
  end

  def fingerprint(ref, tenant, kind) do
    {custodian, _, _} = config()
    custodian.fingerprint(ref, tenant, kind)
  end

  def destroy(ref, tenant) do
    {custodian, _, _} = config()
    custodian.destroy(ref, tenant)
  end

  defp config, do: Application.fetch_env!(:ash_hooks, __MODULE__)
end

defmodule AshHooks.Test.CustodyHmacProvider do
  @moduledoc false
  use AshHooks.Provider
  alias AshHooks.Provider.Signature

  @impl true
  def verify_signature(body, ctx, _secret) do
    case Application.get_env(:ash_hooks, :verification_result) do
      nil ->
        Signature.hmac(
          body,
          ctx.signature,
          Application.fetch_env!(:ash_hooks, :verification_keys)
        )

      result ->
        result
    end
  end

  @impl true
  def parse_event_type(_payload), do: {:ok, :checked}

  @impl true
  def handle_event(type, payload), do: {:ok, %AshHooks.Event{type: type, payload: payload}}
end

defmodule AshHooks.Test.CustodySchemeProvider do
  @moduledoc false
  use AshHooks.Provider,
    verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

  alias AshHooks.Provider.Scheme

  @impl true
  def verify_signature(body, ctx, _secret) do
    Scheme.verify(
      body,
      ctx,
      Application.fetch_env!(:ash_hooks, :verification_keys),
      algorithm: :hmac_sha256,
      signature: {:header, "x-signature"}
    )
  end
end

defmodule AshHooks.Test.CustodyRotationProvider do
  @moduledoc false
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.Signature

  # the declaration's current and previous secrets name the keys this
  # provider verifies with, so either may be a custody key; `{:answer, term}`
  # is a provider that answers outside the verification contract
  @impl true
  def verify_signature(body, ctx, secret) do
    case :ash_hooks |> Application.fetch_env!(:rotation_keys) |> Map.fetch!(secret) do
      {:answer, answer} -> answer
      keys -> Signature.hmac(body, ctx.signature, keys)
    end
  end

  @impl true
  def parse_event_type(_payload), do: {:ok, :checked}

  @impl true
  def handle_event(type, payload), do: {:ok, %AshHooks.Event{type: type, payload: payload}}
end

defmodule AshHooks.Test.CustodySigningCases do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias AshHooks.Custody
  alias AshHooks.Custody.Key
  alias AshHooks.Errors.Invalid.{InvalidSignature, KeyKindMismatch, UnknownKey, UnknownSource}
  alias AshHooks.Errors.Unknown.{KeyUnavailable, UnknownError}
  alias AshHooks.KeyRegistry.Transitions
  alias AshHooks.Legacy
  alias AshHooks.Provider.{Hmac, Scheme, Signature}
  alias AshHooks.Signing
  alias AshHooks.Test.{AnswerCustodian, CustodyHmacProvider, KeyRegistryCases, RealReceiver}
  @compile {:no_warn_undefined, [AshHooks.Plug, Plug.Conn, Plug.Test]}
  require Spark.Test

  @body ~s({"event":"checked"})
  @kind {:standard_webhooks, :v1}

  def setup_all(module, layer, repo, prefix) do
    ctx = KeyRegistryCases.setup_all(module, layer, repo, prefix)
    endpoint = Module.concat(module, SigningEndpoint)

    KeyRegistryCases.compile_endpoint(ctx, endpoint,
      custodian: AnswerCustodian,
      secret_resolver: nil
    )

    ctx = %{ctx | endpoint: endpoint}
    setup_outbound(ctx)
  end

  def clean(ctx) do
    KeyRegistryCases.clean(ctx)
    ctx.repo.query!("DELETE FROM #{ctx.delivery_table}", [], log: false)
    ctx.repo.query!("DELETE FROM #{ctx.attempt_table}", [], log: false)
    ctx.repo.query!("DELETE FROM #{ctx.ledger_table}", [], log: false)
    AnswerCustodian.configure(ctx.custodian, :real, self())

    on_exit(fn ->
      AnswerCustodian.clear()
      Application.delete_env(:ash_hooks, :verification_keys)
      Application.delete_env(:ash_hooks, :verification_result)
      Application.delete_env(:ash_hooks, :custody_byte_key)
      Application.delete_env(:ash_hooks, :rotation_keys)
    end)

    :ok
  end

  def cases do
    [
      :primitives,
      :primitive_errors,
      :sender_refusal,
      :missing_marker,
      :delivery_errors,
      :inbound_errors,
      :inbound_success,
      :inbound_previous_key,
      :unknown_source,
      :custom_tenant
    ]
  end

  def primitives(ctx) do
    material = :crypto.strong_rand_bytes(32)
    key = key!(ctx, @kind, material)
    other = key!(ctx, @kind, :crypto.strong_rand_bytes(32))
    sender = key!(ctx, {:sender_hmac, :sha256}, material)
    mac = :crypto.mac(:hmac, :sha256, material, @body)

    for keys <- [key, [other, key], ["wrong", key], [other, material], sender],
        {encoding, signature} <- [
          hex: Base.encode16(mac, case: :lower),
          base64: Base.encode64(mac)
        ] do
      assert :ok = Signature.hmac(@body, signature, keys, encoding: encoding)

      assert :ok =
               Scheme.verify(
                 @body,
                 %{headers: %{"x-signature" => signature}},
                 keys,
                 algorithm: :hmac_sha256,
                 signature: {:header, "x-signature"},
                 encoding: encoding,
                 key_encoding: :raw
               )
    end

    hex = Base.encode16(mac, case: :lower)

    for keys <- [key, [other, key], ["wrong", key], [sender, "wrong"]] do
      assert :ok = Hmac.verify_signature(@body, %{signature: hex}, keys)
    end

    assert :ok = Hmac.verify_signature(@body, %{signature: hex}, other, previous_secrets: [key])

    assert {:error, %InvalidSignature{}} =
             Hmac.verify_signature(@body, %{signature: hex}, [other, "wrong"])

    assert :ok =
             Scheme.verify(
               @body,
               %{headers: %{"x-signature" => Base.encode64(mac)}},
               key,
               algorithm: :hmac_sha256,
               signature: {:header, "x-signature"},
               encoding: :base64,
               key_encoding: :base64,
               key_prefix: "unused"
             )

    for digest <- [:sha1, :sha384, :sha512] do
      sender = key!(ctx, {:sender_hmac, digest}, material)
      actual_digest = if digest == :sha1, do: :sha, else: digest
      signature = Base.encode16(:crypto.mac(:hmac, actual_digest, material, @body), case: :lower)
      assert :ok = Signature.hmac(@body, signature, sender, digest: digest)
    end

    for invalid <- [binary_part(mac, 0, 31), mutate_last(mac)] do
      assert {:error, error} =
               Signature.hmac(@body, Base.encode64(invalid), key, encoding: :base64)

      assert is_struct(error, InvalidSignature)
    end

    protected = Base.url_encode64(Jason.encode!(%{"alg" => "HS256"}), padding: false)
    payload = Base.url_encode64(@body, padding: false)
    input = protected <> "." <> payload

    token =
      input <>
        "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, material, input), padding: false)

    assert {:ok, @body} = Signature.jws(token, key, alg: "HS256")

    assert :ok =
             Scheme.verify(token, %{}, key,
               algorithm: :hmac_sha256,
               signature: :jws_body
             )

    id = Signing.generate_msg_id()
    timestamp = System.system_time(:second)
    assert_raise ArgumentError, fn -> Signing.sign("invalid.id", timestamp, @body, key) end
    expected = Signing.sign(id, timestamp, @body, "whsec_" <> Base.encode64(material))
    assert Signing.sign(id, timestamp, @body, key) == expected
    assert_raise ArgumentError, fn -> Signing.headers(id, timestamp, @body) end
    headers = Signing.headers(id, timestamp, @body, key)
    assert headers["webhook-signature"] == expected

    flush_custody_verifies()
    seed = :crypto.strong_rand_bytes(32)
    ed = key!(ctx, {:standard_webhooks, :v1a}, seed)
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    ed_signature = Base.encode64(:crypto.sign(:eddsa, :none, @body, [seed, :ed25519]))
    assert :ok = Signature.ed25519(@body, ed_signature, [key, public])
    {stranger, _} = :crypto.generate_key(:eddsa, :ed25519)

    for keys <- [ed, [key, stranger], [stranger, key]] do
      assert {:error, %KeyKindMismatch{}} = Signature.ed25519(@body, ed_signature, keys)
    end

    assert {:error, %KeyKindMismatch{}} = Signature.rsa(@body, ed_signature, key)
    assert {:error, :invalid_signature} = Signature.ed25519(@body, ed_signature, stranger)
    refute_received {:custody_verify, _, _, _}
    headers = Signing.headers(id, timestamp, @body, whsec: key, previous_whsk: ed)
    assert {:ok, _} = Signing.verify(@body, headers, "whpk_" <> Base.encode64(public))
    assert {:ok, _} = Signing.verify(@body, headers, "whsec_" <> Base.encode64(material))

    assert {:error, %KeyKindMismatch{}} =
             Legacy.headers(key, nil, @body, timestamp)

    legacy = key!(ctx, {:legacy_hmac, :sha256}, material)

    assert {:error, %KeyKindMismatch{}} =
             Signing.sign(id, timestamp, @body, legacy)

    previous = key!(ctx, {:legacy_hmac, :sha256}, "previous")

    assert Legacy.headers(legacy, previous, @body, timestamp) ==
             Legacy.headers(material, "previous", @body, timestamp)

    assert Legacy.headers(material, previous, @body, timestamp) ==
             Legacy.headers(material, "previous", @body, timestamp)

    assert Legacy.headers(legacy, nil, @body, timestamp) ==
             Legacy.headers(material, nil, @body, timestamp)

    assert Legacy.headers(legacy, @body, timestamp) ==
             Legacy.headers(material, nil, @body, timestamp)

    for mode <- [:standard, :dual, :legacy] do
      result =
        Signing.headers_for_mode(mode, id, timestamp, @body, whsec: key, legacy_secret: legacy)

      assert is_map(result)
    end

    assert {:ok, _} = AnswerCustodian.public_key(ed.ref, "17", ed.kind)
    assert {:ok, _} = AnswerCustodian.fingerprint(key.ref, "17", key.kind)
    assert :ok = AnswerCustodian.destroy(previous.ref, "17")
  end

  def primitive_errors(ctx) do
    key = key!(ctx, @kind, :crypto.strong_rand_bytes(32))

    for {answer, error_module, _, _} <- errors() do
      AnswerCustodian.configure(ctx.custodian, answer, self())
      assert {:error, error} = Signing.sign("msg_error", 1, @body, key)
      assert error.__struct__ == error_module
      assert {:error, error} = Signing.headers("msg_error", 1, @body, whsec: key)
      assert error.__struct__ == error_module
      assert {:error, error} = Signature.hmac(@body, "00", key)
      assert error.__struct__ == error_module

      for keys <- [key, [key, "byte"], ["byte", key]] do
        assert {:error, error} = Hmac.verify_signature(@body, %{signature: "00"}, keys)
        assert error.__struct__ == error_module
      end

      assert {:error, error} =
               Scheme.verify(@body, %{headers: %{"x-signature" => "00"}}, key,
                 algorithm: :hmac_sha256,
                 signature: {:header, "x-signature"}
               )

      assert error.__struct__ == error_module

      legacy = %{key | kind: {:legacy_hmac, :sha256}}
      assert {:error, error} = Legacy.headers(legacy, nil, @body, 1)
      assert error.__struct__ == error_module
      refute inspect(error) =~ "private_backend"
    end
  end

  def sender_refusal(ctx) do
    key = key!(ctx, {:sender_hmac, :sha256}, "sender")
    assert {:error, :kind_not_allowed} = Signing.sign("msg_sender", 1, @body, key)
    assert {:error, :kind_not_allowed} = Legacy.headers(key, nil, @body, 1)
    assert {:error, :kind_not_allowed} = Custody.sign(key, @body)
    refute_received {:custody_sign, _, _, _}
    owner = endpoint!(ctx, secret_ref: key.ref, secret_kind: key.kind)
    row = delivery!(ctx, owner)
    assert :ok = deliver(ctx, row)
    stored = Ash.get!(ctx.delivery, row.id, authorize?: false, tenant: 17)
    assert stored.status == :dead_letter
    assert stored.last_error == "kind_not_allowed"
    refute_received {:custody_sign, _, _, _}
  end

  def missing_marker(ctx) do
    owner = endpoint!(ctx, secret_ref: "host-key", secret_kind: nil)
    row = delivery!(ctx, owner)
    assert :ok = deliver(ctx, row)
    stored = Ash.get!(ctx.delivery, row.id, authorize?: false, tenant: 17)
    assert stored.status == :dead_letter
    assert stored.last_error == "key_kind_mismatch"
  end

  def delivery_errors(ctx) do
    key = key!(ctx, @kind, :crypto.strong_rand_bytes(32))
    owner = endpoint!(ctx, secret_ref: key.ref, secret_kind: key.kind)
    attach(ctx, key)
    telemetry(self(), [[:ash_hooks, :delivery, :result]])

    for {answer, _module, token, status} <- errors() do
      AnswerCustodian.configure(ctx.custodian, answer, self())
      assert_delivery_error(ctx, owner, token, status)
    end

    AnswerCustodian.configure(ctx.custodian, :real, self())

    for {ref, kind} <- [{"absent", @kind}, {key.ref, {:standard_webhooks, :v1a}}] do
      fresh = Ash.get!(ctx.endpoint, owner.id, authorize?: false, tenant: 17)
      owner = update!(fresh, secret_ref: ref, secret_kind: kind)
      token = if ref == "absent", do: "unknown_key", else: "key_kind_mismatch"
      assert_delivery_error(ctx, owner, token, :dead_letter)
    end

    foreign = key!(ctx, @kind, :crypto.strong_rand_bytes(32), "18")
    fresh = Ash.get!(ctx.endpoint, owner.id, authorize?: false, tenant: 17)
    owner = update!(fresh, secret_ref: foreign.ref, secret_kind: foreign.kind)
    assert_delivery_error(ctx, owner, "unknown_key", :dead_letter)
  end

  defp assert_delivery_error(ctx, owner, token, status) do
    row = delivery!(ctx, owner)
    result = deliver(ctx, row)
    assert result == :ok or match?({:snooze, _}, result)
    stored = Ash.get!(ctx.delivery, row.id, authorize?: false, tenant: 17)
    assert stored.status == status
    assert stored.last_error == token
    attempts = Ash.read!(ctx.attempt, authorize?: false, tenant: 17)
    attempt = Enum.find(attempts, &(&1.delivery_pk["id"] == row.id))
    assert attempt.outcome == status
    assert attempt.reason == token
    assert_receive {:telemetry, [:ash_hooks, :delivery, :result], %{reason: ^token}}
    refute inspect({result, stored, attempts}) =~ "private_backend"
  end

  def inbound_errors(ctx) do
    key = key!(ctx, @kind, :crypto.strong_rand_bytes(32))
    Application.put_env(:ash_hooks, :verification_keys, key)
    telemetry(self(), [[:ash_hooks, :ingress, :verify]])

    for source <- [:hmac, :scheme], {answer, module, token, _} <- errors() do
      AnswerCustodian.configure(ctx.custodian, answer, self())
      assert_inbound_error(ctx, source, module, token)
    end

    AnswerCustodian.configure(ctx.custodian, :real, self())

    for {key, module, token} <- [
          {%{key | ref: "absent"}, UnknownKey, "unknown_key"},
          {%{key | tenant: "18"}, UnknownKey, "unknown_key"},
          {%{key | kind: {:standard_webhooks, :v1a}}, KeyKindMismatch, "key_kind_mismatch"}
        ] do
      Application.put_env(:ash_hooks, :verification_keys, key)
      for source <- [:hmac, :scheme], do: assert_inbound_error(ctx, source, module, token)
    end
  end

  def inbound_success(ctx) do
    material = :crypto.strong_rand_bytes(32)
    key = key!(ctx, @kind, material)
    Application.put_env(:ash_hooks, :verification_keys, key)
    signature = Base.encode16(:crypto.mac(:hmac, :sha256, material, @body), case: :lower)

    assert {:error, :no_webhook_secret} =
             CustodyHmacProvider.webhook_signing_secret(nil, nil)

    for source <- [:hmac, :scheme] do
      assert {:ok, :created, row} =
               AshHooks.Ingress.ingest(ctx.ledger, source, @body, %{
                 signature: signature,
                 headers: %{"x-signature" => signature}
               })

      assert row.status == :processed
    end
  end

  # During a rotation overlap a failed current key falls back to the previous
  # key. When the previous key could not be checked (its custodian is
  # unavailable, the key is unknown or of the wrong kind), that failure is the
  # answer, not the current key's invalid signature: the sender must not be
  # told a request signed with the previous key is forged.
  def inbound_previous_key(ctx) do
    material = :crypto.strong_rand_bytes(32)
    previous = key!(ctx, @kind, material)
    previous_ref = previous.ref
    current = :crypto.strong_rand_bytes(32)

    Application.put_env(:ash_hooks, :rotation_keys, %{
      "current" => current,
      "previous" => previous
    })

    telemetry(self(), [[:ash_hooks, :ingress, :verify]])
    signature = Base.encode16(:crypto.mac(:hmac, :sha256, material, @body), case: :lower)

    assert {:ok, :created, row} =
             AshHooks.Ingress.ingest(ctx.ledger, :rotating, @body, %{signature: signature})

    assert row.status == :processed

    for {answer, module, token, _} <- errors() do
      AnswerCustodian.configure(ctx.custodian, answer, self())
      assert_inbound_error(ctx, :rotating, module, token)
      assert_received {:custody_verify, ^previous_ref, _, _}
    end

    AnswerCustodian.configure(ctx.custodian, :real, self())

    for {answer, module, token} <- [
          {:private_backend, UnknownError, "unknown_error"},
          {{:error, :stale_timestamp}, InvalidSignature, "invalid_signature"}
        ] do
      Application.put_env(:ash_hooks, :rotation_keys, %{
        "current" => current,
        "previous" => {:answer, answer}
      })

      assert_inbound_error(ctx, :rotating, module, token)
    end

    # a current key that could not be checked keeps its own failure

    Application.put_env(:ash_hooks, :rotation_keys, %{
      "current" => %{previous | ref: "absent"},
      "previous" => current
    })

    assert_inbound_error(ctx, :rotating, UnknownKey, "unknown_key")
  end

  defp assert_inbound_error(ctx, source, module, token) do
    assert {:error, error} =
             AshHooks.Ingress.ingest(ctx.ledger, source, @body, %{
               signature: "00",
               headers: %{"x-signature" => "00"}
             })

    assert error.__struct__ == module
    expected = String.to_existing_atom(token)
    assert_receive {:telemetry, [:ash_hooks, :ingress, :verify], %{reason: ^expected}}

    if Code.ensure_loaded?(Plug) do
      opts =
        AshHooks.Plug.init(resource: ctx.ledger, source: source, signature_header: "x-signature")

      conn =
        Plug.Test.conn(:post, "/hooks", @body) |> Plug.Conn.put_req_header("x-signature", "00")

      conn = AshHooks.Plug.call(conn, opts)
      assert conn.status == status(module)
      refute inspect({error, conn.resp_body}) =~ "private_backend"
      assert_receive {:telemetry, [:ash_hooks, :ingress, :verify], %{reason: ^expected}}
    end
  end

  def unknown_source(ctx) do
    assert {:error, error} = AshHooks.Ingress.ingest(ctx.ledger, :missing, @body, %{})
    # The existing absent declaration behavior remains separate from S5 source rows.
    assert is_struct(error, UnknownError)
    telemetry(self(), [[:ash_hooks, :ingress, :verify]])

    for {result, module, token} <- [
          {{:error, :unknown_source}, UnknownSource, "unknown_source"},
          {{:error, UnknownSource.exception([])}, UnknownSource, "unknown_source"},
          {{:error, {:private_backend, "private_backend"}}, UnknownError, "unknown_error"},
          {{:error, UnknownError.exception(error: "private_backend")}, UnknownError,
           "unknown_error"},
          {{:private_backend, "private_backend"}, UnknownError, "unknown_error"}
        ] do
      Application.put_env(:ash_hooks, :verification_result, result)
      assert_inbound_error(ctx, :hmac, module, token)
    end

    if Code.ensure_loaded?(Plug) do
      for {module, expected} <- [
            {UnknownSource, 404},
            {KeyKindMismatch, 500},
            {UnknownKey, 500},
            {KeyUnavailable, 503}
          ] do
        {actual, _, ""} =
          AshHooks.Plug.default_response({:error, module.exception([])}, retry_after: 60)

        assert actual == expected
      end
    end
  end

  def custom_tenant(ctx) do
    module = Module.concat(ctx.endpoint, Custom)
    registry = Module.concat(ctx.endpoint, CustomRegistry)
    ctx = %{ctx | registry: registry} |> Map.put(:tenant_type, AshHooks.Test.CustodyTenantType)
    KeyRegistryCases.compile_registry(ctx)
    on_exit(fn -> purge([registry]) end)

    errors =
      Spark.Test.dsl_errors do
        KeyRegistryCases.compile_endpoint(ctx, Module.concat(module, Unsupported),
          tenant_type: AshHooks.Test.CustodyTenantType
        )
      end

    assert [{_, [error]}] = errors
    assert Exception.message(error) =~ "custody_tenant_key"

    KeyRegistryCases.compile_endpoint(ctx, module,
      tenant_type: AshHooks.Test.CustodyTenantType,
      custodian: AnswerCustodian,
      custody_tenant_key: {__MODULE__, :tenant_key, []}
    )

    ctx = %{ctx | endpoint: module}
    key = key!(ctx, @kind, :crypto.strong_rand_bytes(32))
    assert key.tenant == "tenant:17"

    assert {:ok, owner} =
             Ash.create(
               module,
               %{url: "https://hooks.example.test/custody", tenant_id: 17, secret_ref: key.ref},
               authorize?: false,
               tenant: 17
             )

    owner = update!(owner, secret_kind: key.kind)
    attach(ctx, key)
    # The MFA receives the cast tenant, both when issuing and reading the owner.
    assert {:ok, "tenant:17"} =
             Custody.canonical_tenant(owner.tenant_id, module,
               custody_tenant_key: {__MODULE__, :tenant_key, []}
             )

    assert is_binary(Signing.sign("msg_custom", 1, @body, key))
    assert_receive {:custody_sign, _, "tenant:17", _}
    row = delivery!(ctx, owner)
    AnswerCustodian.configure(ctx.custodian, {:error, :unavailable}, self())
    assert {:snooze, _} = deliver(ctx, row, endpoints: module)
    assert_receive {:custody_sign, _, "tenant:17", _}
  end

  def tenant_key(value) when is_integer(value), do: "tenant:" <> Integer.to_string(value)

  def real_delivery(ctx) do
    session = RealReceiver.open!()
    on_exit(fn -> RealReceiver.close!(session) end)
    material = :crypto.strong_rand_bytes(32)
    seed = :crypto.strong_rand_bytes(32)
    current = key!(ctx, @kind, material)
    previous = key!(ctx, {:standard_webhooks, :v1a}, seed)
    legacy = key!(ctx, {:legacy_hmac, :sha256}, "legacy")
    legacy_previous = key!(ctx, {:legacy_hmac, :sha256}, "old-legacy")

    owner =
      endpoint!(ctx,
        url: RealReceiver.url(session),
        secret_ref: current.ref,
        secret_kind: current.kind,
        previous_secret_ref: previous.ref,
        previous_secret_kind: previous.kind,
        legacy_secret_ref: legacy.ref,
        legacy_secret_kind: legacy.kind,
        legacy_previous_secret_ref: legacy_previous.ref,
        legacy_previous_secret_kind: legacy_previous.kind
      )

    for key <- [current, previous, legacy, legacy_previous], do: attach(ctx, key)
    row = delivery!(ctx, owner, :dual)
    assert :ok = deliver(ctx, row)
    [received] = RealReceiver.requests!(session)
    headers = headers(received)
    assert Base.decode64!(received["request_payload_base64"]) == @body
    assert {:ok, _} = Signing.verify(@body, headers, "whsec_" <> Base.encode64(material))
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    assert {:ok, _} = Signing.verify(@body, headers, "whpk_" <> Base.encode64(public))

    assert {:ok, _} =
             Legacy.verify(
               "legacy",
               @body,
               headers["x-webhook-signature"],
               System.system_time(:second)
             )

    assert headers["x-webhook-signature"] =~ ",v1prev="
    assert_receive {:custody_sign, _, "17", _}

    owner =
      update!(owner,
        previous_secret_ref: "old-byte",
        previous_secret_kind: nil,
        legacy_secret_ref: nil,
        legacy_secret_kind: nil,
        legacy_previous_secret_ref: nil,
        legacy_previous_secret_kind: nil
      )

    byte = Signing.generate_secret()
    Application.put_env(:ash_hooks, :custody_byte_key, byte)
    mixed = Module.concat(ctx.endpoint, Mixed)

    KeyRegistryCases.compile_endpoint(ctx, mixed,
      custodian: AnswerCustodian,
      secret_resolver: {__MODULE__, :resolve_byte}
    )

    ctx = %{ctx | endpoint: mixed}
    owner = Ash.get!(mixed, owner.id, authorize?: false, tenant: 17)
    row = delivery!(ctx, owner)
    assert :ok = deliver(ctx, row)

    received =
      Enum.find(RealReceiver.requests!(session), &(headers(&1)["webhook-id"] == row.event_uuid))

    assert {:ok, _} = Signing.verify(@body, headers(received), byte)

    assert {:ok, _} =
             Signing.verify(@body, headers(received), "whsec_" <> Base.encode64(material))

    assert {:ok, %{status: :succeeded, delivery: test_row}} =
             AshHooks.Delivery.test_send(owner,
               deliveries: ctx.delivery,
               tenant: "017",
               type: :checked,
               destination_policy: fn _, _ -> :allow end,
               http_opts: [validate_destination: false]
             )

    received =
      Enum.find(
        RealReceiver.requests!(session),
        &(headers(&1)["webhook-id"] == test_row.event_uuid)
      )

    body = Base.decode64!(received["request_payload_base64"])
    assert {:ok, _} = Signing.verify(body, headers(received), "whsec_" <> Base.encode64(material))
  end

  def canonical_worker(ctx, owner) do
    ctx = setup_outbound(ctx)
    worker = Module.concat(ctx.endpoint, Worker)

    Code.compile_quoted(
      quote do
        defmodule unquote(worker) do
          use AshHooks.Worker,
            deliveries: unquote(ctx.delivery),
            endpoints: unquote(ctx.endpoint),
            destination_policy: {AshHooks.Test.CustodySigningCases, :allow},
            http_opts: [validate_destination: false]
        end
      end
    )

    on_exit(fn -> purge([worker]) end)
    session = RealReceiver.open!()
    on_exit(fn -> RealReceiver.close!(session) end)
    owner = update!(owner, url: RealReceiver.url(session), legacy_secret_ref: nil)
    row = delivery!(ctx, owner)
    route = AshHooks.OutboundBinding.named_route(worker, :enqueue)
    assert {:ok, row} = AshHooks.Worker.bind_route(row, route, 17)

    assert :ok =
             worker.perform(
               struct(Oban.Job,
                 args: %{
                   "endpoint_id" => owner.id,
                   "event_uuid" => row.event_uuid,
                   "tenant" => "17",
                   "dispatch_route" => row.dispatch_route
                 }
               )
             )

    [received] = RealReceiver.requests!(session)

    assert {:ok, _} =
             Signing.verify(
               @body,
               headers(received),
               "whsec_" <> Base.encode64(:binary.copy(<<42>>, 32))
             )
  end

  def allow(_url, _ctx), do: :allow
  def resolve_byte("old-byte"), do: {:ok, Application.fetch_env!(:ash_hooks, :custody_byte_key)}

  defp errors do
    [
      {{:error, :unavailable}, KeyUnavailable, "key_unavailable", :failed_retryable},
      {{:error, :unknown_ref}, UnknownKey, "unknown_key", :dead_letter},
      {{:error, :kind_mismatch}, KeyKindMismatch, "key_kind_mismatch", :dead_letter},
      {{:error, :not_signable}, KeyKindMismatch, "key_kind_mismatch", :dead_letter},
      {{:error, :invalid_signature}, InvalidSignature, "invalid_signature", :failed_retryable},
      {{:error, {:private_backend, "private_backend"}}, UnknownError, "unknown_error",
       :failed_retryable},
      {{:ok, :private_backend}, UnknownError, "unknown_error", :failed_retryable},
      {:private_backend, UnknownError, "unknown_error", :failed_retryable}
    ]
  end

  defp status(InvalidSignature), do: 400
  defp status(UnknownSource), do: 404

  defp status(module)
       when module in [
              KeyKindMismatch,
              UnknownKey
            ],
       do: 500

  defp status(_), do: 503

  defp telemetry(sink, events) do
    id = make_ref()
    :ok = :telemetry.attach_many(id, events, &__MODULE__.receive_telemetry/4, sink)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def receive_telemetry(event, _measurements, metadata, sink),
    do: send(sink, {:telemetry, event, metadata})

  defp key!(ctx, kind, material, tenant \\ "17") do
    {:ok, row} = Transitions.issue(ctx.endpoint, kind, tenant: tenant)
    assert :ok = AnswerCustodian.store(row.ref, material, row.custody_tenant, kind)
    %Key{custodian: AnswerCustodian, ref: row.ref, tenant: row.custody_tenant, kind: kind}
  end

  defp endpoint!(ctx, attrs) do
    params =
      Map.merge(
        %{url: "https://hooks.example.test/custody", tenant_id: 17, secret_ref: "host-key"},
        Map.new(attrs)
      )

    ctx.endpoint
    |> Ash.Changeset.for_create(
      :create,
      Map.take(params, [:url, :tenant_id]),
      tenant: 17,
      context: %{ash_hooks_issued_attributes: params}
    )
    |> Ash.Changeset.force_change_attributes(params)
    |> Ash.create!(authorize?: false)
  end

  defp update!(owner, attrs) do
    owner
    |> Ash.Changeset.for_update(:update, %{}, tenant: 17)
    |> Ash.Changeset.force_change_attributes(Map.new(attrs))
    |> Ash.update!(authorize?: false)
  end

  defp attach(ctx, key),
    do: assert(match?({:ok, _}, Transitions.attach(ctx.endpoint, key.ref, tenant: 17)))

  defp delivery!(ctx, owner, mode \\ :standard) do
    Ash.create!(
      ctx.delivery,
      %{
        event_uuid: Signing.generate_msg_id(),
        event_type: "checked",
        signing_mode: mode,
        payload: @body,
        endpoint_id: owner.id
      },
      action: :dispatch,
      tenant: 17,
      authorize?: false
    )
  end

  defp deliver(ctx, row, opts \\ []) do
    AshHooks.Delivery.run(
      %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid, "tenant" => "017"},
      Keyword.merge(
        [
          deliveries: ctx.delivery,
          endpoints: ctx.endpoint,
          attempts: ctx.attempt,
          destination_policy: &__MODULE__.allow/2,
          http_opts: [validate_destination: false]
        ],
        opts
      )
    )
  end

  defp headers(request),
    do: Map.new(request["headers"], &{String.downcase(&1["name"]), &1["value"]})

  defp flush_custody_verifies do
    receive do
      {:custody_verify, _, _, _} -> flush_custody_verifies()
    after
      0 -> :ok
    end
  end

  defp mutate_last(mac) do
    size = byte_size(mac) - 1
    <<head::binary-size(^size), last>> = mac
    head <> <<Bitwise.bxor(last, 1)>>
  end

  def setup_outbound(ctx) do
    delivery = Module.concat(ctx.endpoint, Delivery)
    attempt = Module.concat(ctx.endpoint, Attempt)
    ledger = Module.concat(ctx.endpoint, Ledger)

    tables = %{
      delivery => ctx.endpoint_table <> "_deliveries",
      attempt => ctx.endpoint_table <> "_attempts",
      ledger => ctx.endpoint_table <> "_ledger"
    }

    for {module, extension} <- [
          {delivery, AshHooks.OutboundDelivery},
          {attempt, AshHooks.OutboundAttempt},
          {ledger, AshHooks.InboundDelivery}
        ] do
      table = Map.fetch!(tables, module)

      compile_outbound_resource(ctx, module, extension, table, module == ledger)
    end

    id = if ctx.storage == :postgres, do: "UUID", else: "TEXT"
    time = if ctx.storage == :postgres, do: "TIMESTAMP(6)", else: "TEXT"
    bytes = if ctx.storage == :postgres, do: "BYTEA", else: "BLOB"
    json = if ctx.storage == :postgres, do: "JSONB", else: "TEXT"
    dt = tables[delivery]
    at = tables[attempt]
    lt = tables[ledger]

    ctx.repo.query!(
      "CREATE TABLE #{dt} (id #{id} PRIMARY KEY, tenant_id bigint NOT NULL, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL, payload #{bytes} NOT NULL, endpoint_id #{id} NOT NULL, subscription_id #{id}, signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER, response_snippet TEXT, last_error TEXT, next_attempt_at #{time}, dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound', dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound', attempt_token #{id}, send_lease_expires_at #{time}, enqueue_token #{id}, enqueue_lease_expires_at #{time}, endpoint_snapshot #{json})",
      [],
      log: false
    )

    ctx.repo.query!(
      "CREATE UNIQUE INDEX #{dt}_unique_delivery_index ON #{dt} (endpoint_id, event_uuid, tenant_id)",
      [],
      log: false
    )

    ctx.repo.query!(
      "CREATE TABLE #{at} (id #{id} PRIMARY KEY, tenant_id bigint NOT NULL, delivery_pk #{json} NOT NULL, endpoint_id #{id} NOT NULL, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL, attempted_at #{time} NOT NULL, attempt INTEGER NOT NULL, outcome TEXT NOT NULL, reason TEXT, response_status INTEGER, latency_ms INTEGER, signing_key_ref TEXT, response_snippet TEXT, response_headers #{json}, test BOOLEAN NOT NULL DEFAULT FALSE)",
      [],
      log: false
    )

    ctx.repo.query!(
      "CREATE UNIQUE INDEX #{at}_unique_attempt_index ON #{at} (tenant_id, delivery_pk, attempt)",
      [],
      log: false
    )

    ctx.repo.query!(
      "CREATE TABLE #{lt} (id #{id} PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL, external_event_type TEXT, payload #{json} NOT NULL, payload_digest TEXT NOT NULL, status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0, lease_expires_at #{time}, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0)",
      [],
      log: false
    )

    ctx.repo.query!(
      "CREATE UNIQUE INDEX #{lt}_unique_ingest_index ON #{lt} (provider, external_event_id)",
      [],
      log: false
    )

    on_exit(fn ->
      for table <- [dt, at, lt], do: ctx.repo.query!("DROP TABLE #{table}", [], log: false)
      purge([delivery, attempt, ledger])
    end)

    Map.merge(ctx, %{
      delivery: delivery,
      attempt: attempt,
      ledger: ledger,
      delivery_table: dt,
      attempt_table: at,
      ledger_table: lt
    })
  end

  defp compile_outbound_resource(ctx, module, extension, table, inbound?) do
    storage =
      {ctx.storage, [],
       [
         [
           do:
             quote(
               do:
                 (
                   repo(unquote(ctx.repo))
                   table(unquote(table))
                 )
             )
         ]
       ]}

    tenant =
      if not inbound?,
        do:
          quote(
            do:
              (
                attributes(do: attribute(:tenant_id, :integer, allow_nil?: false))

                multitenancy(
                  do:
                    (
                      strategy(:attribute)
                      attribute(:tenant_id)
                    )
                )
              )
          )

    inbound =
      if inbound? do
        quote do
          webhooks do
            inbound :hmac do
              provider AshHooks.Test.CustodyHmacProvider
              secret fn -> {:ok, "unused"} end
            end

            inbound :scheme do
              provider AshHooks.Test.CustodySchemeProvider
              secret fn -> {:ok, "unused"} end
            end

            inbound :rotating do
              provider AshHooks.Test.CustodyRotationProvider
              secret fn -> {:ok, "current"} end
              previous_secret fn -> {:ok, "previous"} end
            end
          end
        end
      end

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Ash.Resource,
            domain: unquote(ctx.domain),
            data_layer: unquote(ctx.layer),
            extensions: unquote(if inbound?, do: [AshHooks, extension], else: [extension])

          unquote(storage)
          unquote(tenant)
          unquote(inbound)

          actions do
            defaults [:read]
          end
        end
      end
    )
  end

  defp purge(modules),
    do:
      Enum.each(modules, fn module ->
        :code.purge(module)
        :code.delete(module)
      end)
end
