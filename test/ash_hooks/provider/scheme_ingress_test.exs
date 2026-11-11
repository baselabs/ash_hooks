defmodule AshHooks.Provider.SchemeIngressTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  require Spark.Test
  alias AshHooks.InboundDelivery.LegacyAdoption
  alias AshHooks.Ingress
  alias AshHooks.Provider.Scheme

  defmodule HeaderProvider do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
  end

  defmodule BodyProvider do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: :jws_body]
  end

  defmodule IdentityProvider do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
    @impl true
    def event_identity(%{"id" => id}) when is_binary(id), do: {:ok, id}
    def event_identity(_), do: {:error, :malformed_payload}
  end

  defmodule TimestampProvider do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "x-signature"},
        timestamp: {:header, "x-time"},
        signed_input: [:timestamp, ".", :body]
      ]
  end

  defmodule CaptureProvider do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

    @impl true
    def verify_signature(raw_body, ctx, keys) do
      send(self(), {:verify_ctx, ctx})
      super(raw_body, ctx, keys)
    end
  end

  defmodule Es256Provider do
    use AshHooks.Provider, verify: [algorithm: :ecdsa_p256_sha256, signature: :jws_body]
  end

  @p256 {1, 2, 840, 10_045, 3, 1, 7}
  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @ec_key :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})

  defmodule SqliteLedger do
    use Ash.Resource,
      domain: AshHooks.Provider.SchemeIngressTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table "scheme_ingress"
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults [:read]
    end

    webhooks do
      inbound :headers do
        provider(AshHooks.Provider.SchemeIngressTest.HeaderProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
        previous_secret({AshHooks.Provider.SchemeIngressTest, :previous_key, []})
      end

      inbound :body do
        provider(AshHooks.Provider.SchemeIngressTest.BodyProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
        previous_secret({AshHooks.Provider.SchemeIngressTest, :previous_key, []})
      end

      inbound :identity do
        provider(AshHooks.Provider.SchemeIngressTest.IdentityProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
      end

      inbound :timestamped do
        provider(AshHooks.Provider.SchemeIngressTest.TimestampProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
        replay_window_seconds 60
      end

      inbound :captured do
        provider(AshHooks.Provider.SchemeIngressTest.CaptureProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
      end

      inbound :es256 do
        provider(AshHooks.Provider.SchemeIngressTest.Es256Provider)
        secret {AshHooks.Provider.SchemeIngressTest, :es256_public_key, []}
      end
    end
  end

  defmodule PostgresLedger do
    use Ash.Resource,
      domain: AshHooks.Provider.SchemeIngressTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    postgres do
      table "scheme_ingress"
      repo(AshHooks.TestPostgres.Repo)
    end

    actions do
      defaults [:read]
    end

    webhooks do
      inbound :headers do
        provider(AshHooks.Provider.SchemeIngressTest.HeaderProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
        previous_secret({AshHooks.Provider.SchemeIngressTest, :previous_key, []})
      end

      inbound :body do
        provider(AshHooks.Provider.SchemeIngressTest.BodyProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
        previous_secret({AshHooks.Provider.SchemeIngressTest, :previous_key, []})
      end

      inbound :identity do
        provider(AshHooks.Provider.SchemeIngressTest.IdentityProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
      end

      inbound :timestamped do
        provider(AshHooks.Provider.SchemeIngressTest.TimestampProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
        replay_window_seconds 60
      end

      inbound :captured do
        provider(AshHooks.Provider.SchemeIngressTest.CaptureProvider)
        secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
      end

      inbound :es256 do
        provider(AshHooks.Provider.SchemeIngressTest.Es256Provider)
        secret {AshHooks.Provider.SchemeIngressTest, :es256_public_key, []}
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource AshHooks.Provider.SchemeIngressTest.SqliteLedger
      resource AshHooks.Provider.SchemeIngressTest.PostgresLedger
    end
  end

  setup_all do
    repos =
      [AshHooks.Test.Repo] ++
        if(System.get_env("ASH_HOOKS_POSTGRES") == "1",
          do: [AshHooks.TestPostgres.Repo],
          else: []
        )

    for repo <- repos do
      {id_type, payload_type, time_type} =
        if repo == AshHooks.Test.Repo,
          do: {"TEXT", "TEXT", "TEXT"},
          else: {"UUID", "JSONB", "TIMESTAMPTZ"}

      repo.query!("""
      CREATE TABLE scheme_ingress (
        id #{id_type} PRIMARY KEY, provider TEXT NOT NULL, external_event_id TEXT NOT NULL,
        external_event_type TEXT, payload #{payload_type} NOT NULL, payload_digest TEXT NOT NULL,
        status TEXT NOT NULL, fencing_token INTEGER NOT NULL DEFAULT 0,
        lease_expires_at #{time_type}, error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0
      )
      """)

      repo.query!(
        "CREATE UNIQUE INDEX scheme_ingress_unique_ingest_index ON scheme_ingress (provider, external_event_id)"
      )
    end

    on_exit(fn -> for repo <- repos, do: repo.query!("DROP TABLE scheme_ingress") end)
    :ok
  end

  setup do
    AshHooks.Test.Repo.query!("DELETE FROM scheme_ingress")

    if System.get_env("ASH_HOOKS_POSTGRES") == "1",
      do: AshHooks.TestPostgres.Repo.query!("DELETE FROM scheme_ingress")

    :ok
  end

  for {ledger, substrate} <- [{SqliteLedger, :sqlite}, {PostgresLedger, :postgres}] do
    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: explicit provider identity is authoritative and malformed identities never reach storage" do
      ledger = unquote(ledger)

      for {body, expected} <- [
            {~s({"id":"stable-1"}), :created},
            {"{}", :error},
            {~s({"id":""}), :error},
            {Jason.encode!(%{id: String.duplicate("x", 256)}), :error}
          ] do
        ctx = %{headers: %{"x-signature" => mac(body, "new-key")}}

        case expected do
          :created ->
            assert {:ok, :created, %{external_event_id: "stable-1"}} =
                     Ingress.ingest(ledger, :identity, body, ctx)

          :error ->
            assert {:error, %AshHooks.Errors.Invalid.MalformedPayload{}} =
                     Ingress.ingest(ledger, :identity, body, ctx)
        end
      end

      assert length(Ash.read!(ledger, authorize?: false)) == 1
    end

    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: header-only verification and previous-secret rotation use the real ledger" do
      ledger = unquote(ledger)

      for key <- ["new-key", "old-key"] do
        body = Jason.encode!(%{key: key})
        ctx = %{headers: %{"X-Signature" => mac(body, key)}}
        assert {:ok, :created, row} = Ingress.ingest(ledger, :headers, body, ctx)
        assert row.status == :processed
        assert row.payload == Jason.decode!(body)
        assert {:ok, :duplicate, _} = Ingress.ingest(ledger, :headers, body, ctx)

        assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
                 Ingress.ingest(ledger, :headers, body <> " ", ctx)
      end

      assert length(Ash.read!(ledger, authorize?: false)) == 2
    end

    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: an ordered header list reaches the provider line by line and as a joined map" do
      body = ~s({"order":1})
      signature = mac(body, "new-key")

      headers = [
        {"X-Signature", signature},
        {"X-Repeat", "a"},
        {"content-type", "application/json"},
        {"x-repeat", "b"}
      ]

      assert {:ok, :created, %{status: :processed}} =
               Ingress.ingest(unquote(ledger), :captured, body, %{headers: headers})

      assert_received {:verify_ctx, ctx}

      assert ctx.header_list == [
               {"x-signature", signature},
               {"x-repeat", "a"},
               {"content-type", "application/json"},
               {"x-repeat", "b"}
             ]

      assert ctx.headers == %{
               "x-signature" => signature,
               "x-repeat" => "a, b",
               "content-type" => "application/json"
             }
    end

    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: a re-encoded JWS signature over the same content is a duplicate" do
      ledger = unquote(ledger)
      claims = %{"event" => "member.joined", "exp" => System.system_time(:second) + 300}
      {token, malleated} = es256_tokens(claims)
      refute token == malleated

      assert {:ok, :created, %{status: :processed} = row} =
               Ingress.ingest(ledger, :es256, token, %{})

      assert {:ok, :duplicate, duplicate} = Ingress.ingest(ledger, :es256, malleated, %{})
      assert duplicate.id == row.id
      assert {:ok, row.external_event_id} == Scheme.payload_identity(claims)

      # an unpadded segment is required, so a padded variant never verifies
      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               Ingress.ingest(ledger, :body, token(claims, "new-key") <> "=", %{})

      assert length(Ash.read!(ledger, authorize?: false)) == 1
    end

    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: a missing signature header fails before a ledger write" do
      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               Ingress.ingest(unquote(ledger), :headers, "{}", %{
                 signature: mac("{}", "new-key"),
                 headers: %{}
               })

      assert [] = Ash.read!(unquote(ledger), authorize?: false)
    end

    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: JWS body payloads decode after verification, including during rotation" do
      ledger = unquote(ledger)

      for key <- ["new-key", "old-key"] do
        claims = %{"key" => key, "exp" => System.system_time(:second) + 300}
        token = token(claims, key)
        assert {:ok, :created, row} = Ingress.ingest(ledger, :body, token, %{})
        assert row.status == :processed
        assert row.payload == claims
        assert row.payload_digest == Base.encode16(:crypto.hash(:sha256, token), case: :lower)

        assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
                 Ingress.ingest(ledger, :body, token <> "x", %{})
      end

      assert length(Ash.read!(ledger, authorize?: false)) == 2
    end

    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: ingress excludes request clock overrides and forwards DSL replay windows" do
      ledger = unquote(ledger)
      timestamp = Integer.to_string(System.system_time(:second) - 61)

      ctx = %{
        headers: %{"x-time" => timestamp, "x-signature" => mac(timestamp <> ".{}", "new-key")},
        now_ms: String.to_integer(timestamp) * 1000
      }

      assert {:error, %AshHooks.Errors.Invalid.StaleTimestamp{}} =
               Ingress.ingest(ledger, :timestamped, "{}", ctx)

      assert [] = Ash.read!(ledger, authorize?: false)
    end
  end

  test "a host map with a non-binary entry passes through, and header_list keeps binary entries" do
    body = ~s({"order":4})
    headers = %{"x-signature" => mac(body, "new-key"), "x-count" => 3}

    assert {:ok, :created, _} =
             Ingress.ingest(SqliteLedger, :captured, body, %{headers: headers})

    assert_received {:verify_ctx, ctx}
    assert ctx.headers == headers
    assert ctx.header_list == [{"x-signature", mac(body, "new-key")}]
  end

  test "a host-supplied header map reaches the provider unchanged" do
    body = ~s({"order":2})
    headers = %{"X-Signature" => mac(body, "new-key"), "X-Repeat" => "kept as given"}

    assert {:ok, :created, _} =
             Ingress.ingest(SqliteLedger, :captured, body, %{headers: headers})

    assert_received {:verify_ctx, ctx}
    assert ctx.headers == headers
    assert ctx.header_list == Map.to_list(headers)
  end

  test "a malformed header set or a repeated signature line fails closed before a ledger write" do
    body = ~s({"order":3})
    signature = mac(body, "new-key")

    for headers <- [
          [{"x-signature", signature}, {"x-repeat", :not_a_binary}],
          [{"x-signature", signature} | :improper],
          "x-signature: #{signature}",
          [{"x-signature", signature}, {"x-signature", signature}]
        ] do
      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               Ingress.ingest(SqliteLedger, :captured, body, %{headers: headers})
    end

    assert [] = Ash.read!(SqliteLedger, authorize?: false)
  end

  test "an inbound without an explicit provider has an actionable compile-time error" do
    errors =
      Spark.Test.dsl_errors do
        defmodule MissingProvider do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Simple, extensions: [AshHooks]

          attributes do
            uuid_primary_key :id
          end

          webhooks do
            inbound :orders do
              secret {AshHooks.Provider.SchemeIngressTest, :current_key, []}
            end
          end
        end
      end

    assert [{_, [%Spark.Error.DslError{} = error]}] = errors
    assert error.message =~ "inbound :orders has no provider"
    assert error.message =~ "use AshHooks.Provider, verify:"
    resource = Module.concat(__MODULE__, "MissingProvider")

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             Ingress.ingest(resource, :orders, "{}", %{})

    assert {:error, :provider_identity_not_supported} =
             LegacyAdoption.plan(resource, :orders)
  end

  def es256_public_key do
    {:ECPrivateKey, _, _, curve, point, _} = @ec_key

    {:ok,
     :public_key.pem_encode([
       :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, point}, curve})
     ])}
  end

  # A valid ES256 token and the same token with its signature's s replaced by
  # n - s: both verify over identical content.
  defp es256_tokens(claims) do
    input =
      Base.url_encode64(~s({"alg":"ES256"}), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    der = :public_key.sign(input, :sha256, @ec_key)
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    encode = fn s -> Base.url_encode64(<<r::256, s::256>>, padding: false) end
    _ = @p256
    {input <> "." <> encode.(s), input <> "." <> encode.(@p256_order - s)}
  end

  def current_key, do: {:ok, "new-key"}
  def previous_key, do: {:ok, "old-key"}
  defp mac(body, key), do: :crypto.mac(:hmac, :sha256, key, body) |> Base.encode16(case: :lower)

  defp token(claims, key) do
    input =
      Base.url_encode64(~s({"alg":"HS256"}), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    input <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, key, input), padding: false)
  end
end
