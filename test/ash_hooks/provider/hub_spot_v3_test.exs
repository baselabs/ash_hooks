defmodule AshHooks.Provider.HubSpotV3Test do
  @moduledoc """
  The HubSpot v3 vendor verifier: provider-published vector (the official
  docs page's own Java example, openssl-reproduced 2026-08-21 — never
  self-signed), scheme floors (the method/URI/timestamp-header bindings a
  roundtrip-only suite cannot prove), the one-sided replay window, the
  documented URI decode map, and the vendor-documented 41-entry
  subscriptionType taxonomy (webhooks guide, fetched first-hand 2026-08-21;
  9/9 cross-check against the incumbent's production set).
  """

  use ExUnit.Case, async: true

  alias AshHooks.Provider
  alias AshHooks.Provider.HubSpotV3

  # The docs page's published v3 example, transcribed byte-for-byte. Digest
  # reproduced locally with openssl 2026-08-21 BEFORE any implementation:
  # HMAC-SHA256 over "POST" <> uri <> body <> ts under the example secret
  # base64-encodes to exactly the published signature.
  @vector_secret "cfc68c0b-4b4e-4ef8-b764-95350e4ea479"
  @vector_method "POST"
  @vector_uri "https://webhook.site/335453f5-94b3-49d9-b684-a55354d4b8df"
  @vector_body ~s([{"eventId":531833541,"subscriptionId":3923621,"portalId":48807704,"appId":16111050,"occurredAt":1752613920733,"subscriptionType":"contact.creation","attemptNumber":0,"objectId":138017612137,"changeFlag":"CREATED","changeSource":"CRM_UI","sourceId":"userId:76023669"}])
  @vector_timestamp "1752613922216"
  @vector_signature "gbj1XPRvUt0noT7i7fXfTzOD4sLzQmf0VT28ZYq0EYg="
  # Milliseconds — the v3 timestamp header's unit (not unix seconds).
  @vector_now_ms 1_752_613_922_216

  # The vendor's documented taxonomy (webhooks guide, 2026-08-21): 41
  # subscriptionTypes across seven objects. The test pins every entry —
  # dropping one silently downgrades a real vendor event to
  # unknown_event_type.
  @taxonomy %{
    "contact.creation" => :contact_creation,
    "contact.deletion" => :contact_deletion,
    "contact.merge" => :contact_merge,
    "contact.associationChange" => :contact_association_change,
    "contact.restore" => :contact_restore,
    "contact.privacyDeletion" => :contact_privacy_deletion,
    "contact.propertyChange" => :contact_property_change,
    "company.creation" => :company_creation,
    "company.deletion" => :company_deletion,
    "company.propertyChange" => :company_property_change,
    "company.associationChange" => :company_association_change,
    "company.restore" => :company_restore,
    "company.merge" => :company_merge,
    "deal.creation" => :deal_creation,
    "deal.deletion" => :deal_deletion,
    "deal.associationChange" => :deal_association_change,
    "deal.restore" => :deal_restore,
    "deal.merge" => :deal_merge,
    "deal.propertyChange" => :deal_property_change,
    "ticket.creation" => :ticket_creation,
    "ticket.deletion" => :ticket_deletion,
    "ticket.propertyChange" => :ticket_property_change,
    "ticket.associationChange" => :ticket_association_change,
    "ticket.restore" => :ticket_restore,
    "ticket.merge" => :ticket_merge,
    "product.creation" => :product_creation,
    "product.deletion" => :product_deletion,
    "product.restore" => :product_restore,
    "product.merge" => :product_merge,
    "product.propertyChange" => :product_property_change,
    "line_item.creation" => :line_item_creation,
    "line_item.deletion" => :line_item_deletion,
    "line_item.associationChange" => :line_item_association_change,
    "line_item.restore" => :line_item_restore,
    "line_item.merge" => :line_item_merge,
    "line_item.propertyChange" => :line_item_property_change,
    "conversation.creation" => :conversation_creation,
    "conversation.deletion" => :conversation_deletion,
    "conversation.privacyDeletion" => :conversation_privacy_deletion,
    "conversation.propertyChange" => :conversation_property_change,
    "conversation.newMessage" => :conversation_new_message
  }

  defp ctx(opts \\ []) do
    ctx = %{
      signature: Keyword.get(opts, :signature, @vector_signature),
      headers: Keyword.get(opts, :headers, %{"x-hubspot-request-timestamp" => @vector_timestamp}),
      method: Keyword.get(opts, :method, @vector_method),
      request_uri: Keyword.get(opts, :request_uri, @vector_uri)
    }

    ctx
    |> maybe(:now_ms, opts[:now_ms])
    |> maybe(:replay_window_seconds, opts[:replay_window_seconds])
  end

  defp maybe(ctx, _key, nil), do: ctx
  defp maybe(ctx, key, value), do: Map.put(ctx, key, value)

  # Self-signed fixtures are for FLOORS and window pins only — the conformance
  # anchor is the published vector above.
  defp sign(secret, method, uri, body, timestamp),
    do: :crypto.mac(:hmac, :sha256, secret, method <> uri <> body <> timestamp) |> Base.encode64()

  defp flip_first_byte(<<first, rest::binary>>),
    do: <<if(first == ?x, do: ?y, else: ?x), rest::binary>>

  defp fresh_ts, do: Integer.to_string(System.system_time(:millisecond))

  describe "verify_signature/3 — provider-published vector" do
    test "accepts the docs' own Java-example vector verbatim" do
      assert :ok =
               HubSpotV3.verify_signature(
                 @vector_body,
                 ctx(now_ms: @vector_now_ms),
                 @vector_secret
               )
    end

    test "the same vector with no clock override is stale — the 300s window defaults on" do
      assert {:error, :stale_timestamp} =
               HubSpotV3.verify_signature(@vector_body, ctx(), @vector_secret)
    end
  end

  describe "verify_signature/3 — tamper + scheme floors" do
    @uri "https://hooks.example.com/webhooks/hubspot"
    @body ~s([{"eventId":1,"subscriptionType":"contact.creation","objectId":2}])
    @ts Integer.to_string(@vector_now_ms)
    @secret "hs-floor-secret"

    test "rejects a body whose FIRST byte was tampered" do
      signature = sign(@secret, "POST", @uri, @body, @ts)

      assert {:error, :invalid_signature} =
               HubSpotV3.verify_signature(
                 flip_first_byte(@body),
                 ctx(signature: signature, request_uri: @uri, now_ms: @vector_now_ms),
                 @secret
               )
    end

    test "rejects a signature computed under a different secret" do
      signature = sign("other-secret", "POST", @uri, @body, @ts)

      assert {:error, :invalid_signature} =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(signature: signature, request_uri: @uri, now_ms: @vector_now_ms),
                 @secret
               )
    end

    test "an EMPTY secret fails closed as :no_webhook_secret (empty-key HMAC is forgeable)" do
      forged = sign("", "POST", @uri, @body, @ts)

      assert {:error, :no_webhook_secret} =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(signature: forged, request_uri: @uri, now_ms: @vector_now_ms),
                 ""
               )
    end

    test "rejects a signature bound to a different METHOD — the scheme signs the method" do
      signature = sign(@secret, "POST", @uri, @body, @ts)

      assert {:error, :invalid_signature} =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(
                   signature: signature,
                   method: "GET",
                   request_uri: @uri,
                   now_ms: @vector_now_ms
                 ),
                 @secret
               )
    end

    test "rejects a signature bound to a different REQUEST URI" do
      signature = sign(@secret, "POST", @uri, @body, @ts)

      assert {:error, :invalid_signature} =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(signature: signature, request_uri: @uri <> "/evil", now_ms: @vector_now_ms),
                 @secret
               )
    end

    test "rejects a signature bound to a different TIMESTAMP HEADER value" do
      signature = sign(@secret, "POST", @uri, @body, @ts)

      assert {:error, :invalid_signature} =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(
                   signature: signature,
                   headers: %{"x-hubspot-request-timestamp" => "1752619222216"},
                   request_uri: @uri,
                   now_ms: @vector_now_ms
                 ),
                 @secret
               )
    end

    test "a missing method or request URI fails closed as a tuple, never a crash" do
      signature = sign(@secret, "POST", @uri, @body, @ts)

      for broken <- [
            ctx(signature: signature, method: nil, request_uri: @uri, now_ms: @vector_now_ms),
            ctx(signature: signature, request_uri: nil, now_ms: @vector_now_ms),
            ctx(signature: signature, method: :post, request_uri: @uri, now_ms: @vector_now_ms),
            ctx(signature: signature, request_uri: %{evil: true}, now_ms: @vector_now_ms)
          ] do
        assert {:error, :invalid_signature} = HubSpotV3.verify_signature(@body, broken, @secret)
      end
    end

    test "wrong-length, non-base64, and empty signature headers reject as tuples" do
      for bad <- ["", "gbj1", "not base64!", String.duplicate("A", 44) <> "=="] do
        assert {:error, :invalid_signature} =
                 HubSpotV3.verify_signature(
                   @body,
                   ctx(signature: bad, request_uri: @uri, now_ms: @vector_now_ms),
                   @secret
                 )
      end
    end
  end

  describe "verify_signature/3 — the timestamp header" do
    @uri "https://hooks.example.com/webhooks/hubspot"
    @body ~s([])
    @secret "hs-ts-secret"

    test "missing, empty, malformed, and multi-value timestamp headers fail closed" do
      signature = sign(@secret, "POST", @uri, @body, fresh_ts())

      for headers <- [
            %{},
            %{"x-hubspot-request-timestamp" => ""},
            %{"x-hubspot-request-timestamp" => "abc"},
            %{"x-hubspot-request-timestamp" => "1752613922216extra"},
            %{"x-hubspot-request-timestamp" => ["1752613922216", "1"]},
            %{"other-header" => "1752613922216"}
          ] do
        assert {:error, :invalid_signature} =
                 HubSpotV3.verify_signature(
                   @body,
                   ctx(signature: signature, headers: headers, request_uri: @uri),
                   @secret
                 )
      end
    end

    test "a MIXED-CASE timestamp header key still resolves (header names are case-insensitive)" do
      timestamp = fresh_ts()
      signature = sign(@secret, "POST", @uri, @body, timestamp)

      assert :ok =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(
                   signature: signature,
                   headers: %{"X-HubSpot-Request-Timestamp" => timestamp},
                   request_uri: @uri
                 ),
                 @secret
               )
    end
  end

  describe "verify_signature/3 — the replay window" do
    @uri "https://hooks.example.com/webhooks/hubspot"
    @body ~s([])
    @secret "hs-window-secret"
    @now_ms 1_752_613_922_216

    test "a delivery ten minutes old is stale under the vendor-default window" do
      aged = Integer.to_string(@now_ms - 600_000)
      signature = sign(@secret, "POST", @uri, @body, aged)

      assert {:error, :stale_timestamp} =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(
                   signature: signature,
                   headers: %{"x-hubspot-request-timestamp" => aged},
                   request_uri: @uri,
                   now_ms: @now_ms
                 ),
                 @secret
               )
    end

    test "a FUTURE timestamp verifies — the window is one-sided past-only, like the vendor samples" do
      future = Integer.to_string(@now_ms + 600_000)
      signature = sign(@secret, "POST", @uri, @body, future)

      assert :ok =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(
                   signature: signature,
                   headers: %{"x-hubspot-request-timestamp" => future},
                   request_uri: @uri,
                   now_ms: @now_ms
                 ),
                 @secret
               )
    end

    test "the DSL replay_window_seconds overrides the vendor default in both directions" do
      hour_old = Integer.to_string(@now_ms - 3_600_000)
      aged_signature = sign(@secret, "POST", @uri, @body, hour_old)

      # widened: an hour-old delivery passes under a day window
      assert :ok =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(
                   signature: aged_signature,
                   headers: %{"x-hubspot-request-timestamp" => hour_old},
                   request_uri: @uri,
                   now_ms: @now_ms,
                   replay_window_seconds: 86_400
                 ),
                 @secret
               )

      # tightened: a five-minute-old delivery is stale under a minute window
      five_min_old = Integer.to_string(@now_ms - 300_000)
      tight_signature = sign(@secret, "POST", @uri, @body, five_min_old)

      assert {:error, :stale_timestamp} =
               HubSpotV3.verify_signature(
                 @body,
                 ctx(
                   signature: tight_signature,
                   headers: %{"x-hubspot-request-timestamp" => five_min_old},
                   request_uri: @uri,
                   now_ms: @now_ms,
                   replay_window_seconds: 60
                 ),
                 @secret
               )
    end
  end

  describe "decode_request_uri/1 — the documented percent-decode map" do
    test "decodes every documented encoding (upper-case hex)" do
      assert HubSpotV3.decode_request_uri("https://host/%3A%2F%3F%40%21%24%27%28%29%2A%2C%3B") ==
               "https://host/:/?@!$'()*,;"
    end

    test "decodes lower-case percent-hex identically (RFC 3986 case-insensitivity)" do
      assert HubSpotV3.decode_request_uri("https://host/a%3ab%2fc") == "https://host/a:b/c"
    end

    test "leaves unencoded characters — including the query separator — untouched" do
      uri = "https://host/webhooks/hubspot?a=1&b=2"

      assert HubSpotV3.decode_request_uri(uri) == uri
    end

    test "an encoded URI in the context verifies against a signature over the DECODED form" do
      body = ~s([])
      timestamp = Integer.to_string(@vector_now_ms)
      # signed over the decoded path
      signature = sign(@vector_secret, "POST", "https://host/a:b/c", body, timestamp)

      assert :ok =
               HubSpotV3.verify_signature(
                 body,
                 ctx(
                   signature: signature,
                   request_uri: "https://host/a%3Ab%2Fc",
                   headers: %{"x-hubspot-request-timestamp" => timestamp},
                   now_ms: @vector_now_ms
                 ),
                 @vector_secret
               )
    end
  end

  describe "parse_event_type/1 — batch taxonomy allowlist" do
    test "maps every documented subscriptionType to a pre-existing atom (no atom creation)" do
      for {raw, type} <- @taxonomy do
        assert {:ok, ^type} = HubSpotV3.parse_event_type([%{"subscriptionType" => raw}])
      end
    end

    test "a homogeneous batch collapses to its subscriptionType" do
      batch = [
        %{"subscriptionType" => "contact.creation", "objectId" => 1},
        %{"subscriptionType" => "contact.creation", "objectId" => 2}
      ]

      assert {:ok, :contact_creation} = HubSpotV3.parse_event_type(batch)
    end

    test "a mixed batch of KNOWN types maps to :mixed — the consumer fans out" do
      batch = [
        %{"subscriptionType" => "contact.creation"},
        %{"subscriptionType" => "deal.propertyChange"}
      ]

      assert {:ok, :mixed} = HubSpotV3.parse_event_type(batch)
    end

    test "an unknown subscriptionType anywhere in the batch fails closed" do
      batch = [
        %{"subscriptionType" => "contact.creation"},
        %{"subscriptionType" => "contact.timetravel"}
      ]

      assert {:error, :unknown_event_type} = HubSpotV3.parse_event_type(batch)
    end

    test "empty batches, non-map elements, and missing/non-binary types are malformed" do
      for payload <- [
            [],
            ["contact.creation"],
            [%{}],
            [%{"subscriptionType" => nil}],
            [%{"subscriptionType" => 42}],
            %{"subscriptionType" => "contact.creation"},
            "contact.creation"
          ] do
        assert {:error, :malformed_payload} = HubSpotV3.parse_event_type(payload)
      end
    end
  end

  describe "handle_event/2" do
    test "echoes a generic typed event carrying the full batch (domain mapping is consumer-side)" do
      payload = [%{"subscriptionType" => "contact.creation", "objectId" => 2}]

      assert {:ok, %HubSpotV3.Event{type: :contact_creation, payload: ^payload}} =
               HubSpotV3.handle_event(:contact_creation, payload)
    end
  end

  describe "scheme defaults" do
    test "secret scope is app-level — the app client secret rides the DSL secret source" do
      assert Provider.secret_scope(HubSpotV3) == :app_level
    end

    test "declares the v3 timestamp header (the replay window hangs off it)" do
      assert Provider.timestamp_header(HubSpotV3) == "x-hubspot-request-timestamp"
    end
  end
end

defmodule AshHooks.Provider.HubSpotV3E2ETest do
  @moduledoc """
  Runtime smoke through the real DSL surface: a convention-resolved
  `inbound :hub_spot_v3` on a real sqlite ledger — including a top-level
  ARRAY body (HubSpot's documented wire shape) and a wide-window twin that
  carries the published vector through the full pipeline.
  """

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.Provider.HubSpotV3E2ETest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("hub_spot_v3_e2e_ledgers")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :hub_spot_v3 do
        secret {AshHooks.Provider.HubSpotV3E2ETest, :secret, []}
      end

      # Wide-window twin: proves the DSL window override end-to-end AND
      # carries the (aged) published vector through the full pipeline.
      inbound :hub_spot_v3_wide do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.Provider.HubSpotV3E2ETest, :secret, []}

        replay_window_seconds(
          div(System.system_time(:millisecond) - 1_752_613_922_216, 1000) + 3_600
        )
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.Provider.HubSpotV3E2ETest.Ledger)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Ingress
  alias AshHooks.Test.Repo

  @table "hub_spot_v3_e2e_ledgers"
  @uri "https://hooks.example.com/webhooks/hubspot"
  @method "POST"

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@table} (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      external_event_id TEXT NOT NULL,
      external_event_type TEXT,
      payload TEXT NOT NULL,
      payload_digest TEXT NOT NULL,
      status TEXT NOT NULL,
      fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT,
      error_class TEXT,
      attempts INTEGER NOT NULL DEFAULT 0
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_unique_ingest_index ON #{@table} (provider, external_event_id)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@table}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@table}")
    :ok
  end

  # The published vector's own secret, supplied through the DSL secret source —
  # the app-level convention.
  def secret, do: {:ok, "cfc68c0b-4b4e-4ef8-b764-95350e4ea479"}

  defp fresh_ts, do: Integer.to_string(System.system_time(:millisecond))

  defp sign(body, ts),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        "cfc68c0b-4b4e-4ef8-b764-95350e4ea479",
        @method <> @uri <> body <> ts
      )
      |> Base.encode64()

  defp deliver(name, body, ts),
    do: %{
      signature: sign(body, ts),
      headers: %{"x-hubspot-request-timestamp" => ts},
      method: @method,
      request_uri: @uri
    }

  defp batch(type, object_id) do
    Jason.encode!([
      %{
        "eventId" => object_id,
        "subscriptionId" => 3_923_621,
        "portalId" => 48_807_704,
        "appId" => 16_111_050,
        "occurredAt" => System.system_time(:millisecond),
        "subscriptionType" => type,
        "attemptNumber" => 0,
        "objectId" => object_id,
        "changeFlag" => "CREATED",
        "changeSource" => "CRM_UI"
      }
    ])
  end

  defp rows(provider \\ :hub_spot_v3) do
    require Ash.Query

    Ash.Query.filter(Ledger, provider == ^provider) |> Ash.read!(authorize?: false)
  end

  test "an array-body delivery verifies and processes through the fenced pipeline" do
    raw = batch("contact.creation", 101)
    ts = fresh_ts()

    assert {:ok, :created, delivery_row} =
             Ingress.ingest(Ledger, :hub_spot_v3, raw, deliver(:hub_spot_v3, raw, ts))

    assert delivery_row.status == :processed
    assert delivery_row.external_event_type == "contact_creation"
    # the ARRAY wire shape survives into the ledger of record
    assert is_list(delivery_row.payload)
    assert [%{"subscriptionType" => "contact.creation"}] = delivery_row.payload
    assert [%{status: :processed}] = rows()
  end

  test "a byte-identical redelivery is a duplicate no-op (content-digest identity — eventId is not unique per the docs)" do
    raw = batch("deal.creation", 202)
    ts = fresh_ts()

    assert {:ok, :created, _} =
             Ingress.ingest(Ledger, :hub_spot_v3, raw, deliver(:hub_spot_v3, raw, ts))

    assert {:ok, :duplicate, delivery_row} =
             Ingress.ingest(Ledger, :hub_spot_v3, raw, deliver(:hub_spot_v3, raw, ts))

    assert delivery_row.status == :processed
    assert [%{attempts: 1}] = rows()
  end

  test "a tampered delivery is rejected BEFORE any ledger write" do
    raw = batch("contact.creation", 303)
    ts = fresh_ts()
    tampered = flip_first_byte(raw)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             Ingress.ingest(Ledger, :hub_spot_v3, tampered, deliver(:hub_spot_v3, raw, ts))

    assert [] = rows()
  end

  test "an aged delivery under the vendor-default window is stale before any write" do
    raw = batch("contact.creation", 404)
    aged_ts = Integer.to_string(System.system_time(:millisecond) - 600_000)

    assert {:error, %AshHooks.Errors.Invalid.StaleTimestamp{}} =
             Ingress.ingest(Ledger, :hub_spot_v3, raw, deliver(:hub_spot_v3, raw, aged_ts))

    assert [] = rows()
  end

  test "a mixed batch records :mixed and still processes" do
    raw =
      Jason.encode!([
        %{"subscriptionType" => "contact.creation", "objectId" => 1},
        %{"subscriptionType" => "company.propertyChange", "objectId" => 2}
      ])

    ts = fresh_ts()

    assert {:ok, :created, delivery_row} =
             Ingress.ingest(Ledger, :hub_spot_v3, raw, deliver(:hub_spot_v3, raw, ts))

    assert delivery_row.status == :processed
    assert delivery_row.external_event_type == "mixed"
  end

  test "the published vector processes verbatim through the wide-window inbound" do
    vector_body =
      ~s([{"eventId":531833541,"subscriptionId":3923621,"portalId":48807704,"appId":16111050,"occurredAt":1752613920733,"subscriptionType":"contact.creation","attemptNumber":0,"objectId":138017612137,"changeFlag":"CREATED","changeSource":"CRM_UI","sourceId":"userId:76023669"}])

    assert {:ok, :created, delivery_row} =
             Ingress.ingest(
               Ledger,
               :hub_spot_v3_wide,
               vector_body,
               %{
                 signature: "gbj1XPRvUt0noT7i7fXfTzOD4sLzQmf0VT28ZYq0EYg=",
                 headers: %{"x-hubspot-request-timestamp" => "1752613922216"},
                 method: "POST",
                 request_uri: "https://webhook.site/335453f5-94b3-49d9-b684-a55354d4b8df"
               }
             )

    assert delivery_row.status == :processed
    assert delivery_row.external_event_type == "contact_creation"
    assert [%{status: :processed}] = rows(:hub_spot_v3_wide)
  end

  defp flip_first_byte(<<first, rest::binary>>),
    do: <<if(first == ?x, do: ?y, else: ?x), rest::binary>>
end
