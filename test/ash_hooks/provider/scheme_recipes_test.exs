defmodule AshHooks.Provider.SchemeRecipesTest do
  use ExUnit.Case, async: true
  alias AshHooks.Test.Documentation, as: Docs

  setup context do
    Docs.track_test(context)
  end

  @rfc_n "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ"
  @rfc_jwt "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw"
  @vector_secret "cfc68c0b-4b4e-4ef8-b764-95350e4ea479"
  @vector_method "POST"
  @vector_uri "https://webhook.site/335453f5-94b3-49d9-b684-a55354d4b8df"
  @vector_body ~s([{"eventId":531833541,"subscriptionId":3923621,"portalId":48807704,"appId":16111050,"occurredAt":1752613920733,"subscriptionType":"contact.creation","attemptNumber":0,"objectId":138017612137,"changeFlag":"CREATED","changeSource":"CRM_UI","sourceId":"userId:76023669"}])
  @vector_timestamp "1752613922216"
  @vector_signature "gbj1XPRvUt0noT7i7fXfTzOD4sLzQmf0VT28ZYq0EYg="
  @vector_now_ms 1_752_613_922_216

  defmodule GitHub do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "x-hub-signature-256", prefix: "sha256="}
      ]
  end

  defmodule Standard do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature:
          {:structured_header, "webhook-signature",
           signature_key: "v1", pair_separator: " ", key_value_separator: ","},
        encoding: :base64,
        key_prefix: "whsec_",
        key_encoding: :base64,
        timestamp: {:header, "webhook-timestamp"},
        signed_input: [{:header, "webhook-id"}, ".", :timestamp, ".", :body]
      ]
  end

  defmodule StandardAsymmetric do
    use AshHooks.Provider,
      verify: [
        algorithm: :ed25519,
        signature:
          {:structured_header, "webhook-signature",
           signature_key: "v1a", pair_separator: " ", key_value_separator: ","},
        encoding: :base64,
        key_prefix: "whpk_",
        key_encoding: :base64,
        timestamp: {:header, "webhook-timestamp"},
        signed_input: [{:header, "webhook-id"}, ".", :timestamp, ".", :body]
      ]
  end

  test "ComplyCube lowercase hex body HMAC preserves the published PHP SDK answer" do
    # https://docs.complycube.com/documentation/webhooks
    provider = Docs.compile("upgrade-identity-checks-provider")
    ctx = %{
      headers: %{
        "complycube-signature" =>
          "bc00414fa4d54277a3ed01e5ee258d9800a918a7791c7cda16d38b82f38f2150"
      }
    }

    assert_body_hmac_answer!(provider)

    assert {:error, :invalid_signature} =
             provider.verify_signature(~s({"id":"Value"}), ctx, "a_webhook_signature")

    assert_raw_identity!(provider)

    for {raw, type} <- identity_check_types() do
      payload = %{"type" => raw}
      assert {:ok, ^type} = provider.parse_event_type(payload)

      assert {:ok, %AshHooks.Provider.Event{type: ^type, payload: ^payload}} =
               provider.handle_event(type, payload)
    end

    assert {:error, :unknown_event_type} = provider.parse_event_type(%{"type" => "new.type"})
    assert {:error, :malformed_payload} = provider.parse_event_type(%{})
    assert {:error, :malformed_payload} = provider.parse_event_type(%{"type" => nil})
  end

  test "Shopify and WooCommerce base64 body HMAC preserve Shopify's SDK known answer" do
    # https://shopify.dev/docs/apps/build/webhooks/verify-deliveries
    # https://woocommerce.com/document/webhooks/#webhook-delivery
    # https://github.com/Shopify/shopify-api-js/blob/main/packages/shopify-api/lib/webhooks/__tests__/validate.test.ts
    for {name, header} <- [
          {"upgrade-storefront-provider", "x-shopify-hmac-sha256"},
          {"upgrade-store-orders-provider", "x-wc-webhook-signature"}
        ] do
      provider = Docs.compile(name)
      ctx = %{headers: %{header => "B23tXN681gZ0qIWNRrgtzBE9XSDo5yaUu6wfmhu3a7g="}}
      assert :ok = provider.verify_signature(~s({"foo": "bar"}), ctx, "test_secret_key")

      assert {:error, :invalid_signature} =
               provider.verify_signature(~s({"foo": "baz"}), ctx, "test_secret_key")

      assert_default_event!(provider)
    end
  end

  test "GitHub prefix and lowercase hex match the published Hello World example" do
    # https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries
    ctx = %{
      headers: %{
        "X-Hub-Signature-256" =>
          "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"
      }
    }

    assert :ok = GitHub.verify_signature("Hello, World!", ctx, "It's a Secret to Everybody")

    assert {:error, :invalid_signature} =
             GitHub.verify_signature("Hello, world!", ctx, "It's a Secret to Everybody")
  end

  test "Stripe and Shippo structured timestamp.body HMAC recipes reject tampering and stale delivery" do
    # https://docs.stripe.com/webhooks/signature
    # https://docs.goshippo.com/tracking/webhook-security
    body = ~s({"id":"evt_1","type":"order.created"})

    for {name, header} <- [
          {"upgrade-payments-provider", "stripe-signature"},
          {"upgrade-shipping-rates-provider", "shippo-auth-signature"}
        ] do
      provider = Docs.compile(name)
      ctx = %{
        headers: %{
          header =>
            "t=1700000000,v1=bad,v1=14852ee51817599372538c265e8d14af52a5c81c9a7daa1424f386b1b0bb5913"
        },
        now_ms: 1_700_000_000_000
      }

      assert :ok = provider.verify_signature(body, ctx, "test-key")

      assert {:error, :invalid_signature} =
               provider.verify_signature(body <> " ", ctx, "test-key")

      assert {:error, :stale_timestamp} =
               provider.verify_signature(body, %{ctx | now_ms: ctx.now_ms + 301_000}, "test-key")

      assert_default_event!(provider)
    end
  end

  test "Squarespace hex key recipe preserves the independent known answer" do
    # https://commerce-apis.squarespace.com/webhooks/verifying-notifications
    provider = Docs.compile("upgrade-site-events-provider")
    body = ~s({"id":"evt_1","type":"order.created"})

    ctx = %{
      headers: %{
        "squarespace-signature" =>
          "12b0172d33523547e4f806a5e4612133fc21bf99237987639de5c1f8ea320813"
      }
    }

    assert :ok = provider.verify_signature(body, ctx, "abcdef0123456789")

    assert {:error, :invalid_signature} =
             provider.verify_signature(body <> " ", ctx, "abcdef0123456789")

    assert_default_event!(provider)
  end

  test "Ecwid host canonicalization binds eventCreated.eventId and leaves entity data unsigned" do
    # https://github.com/Ecwid/ecwid-api-docs/blob/master/includes/_webhooks.md#webhooks-security
    provider = Docs.compile("upgrade-catalog-events-provider")
    body =
      ~s({"eventId":"80aece08-40e8-4145-8764-6c2f0d38678","eventCreated":1234567,"entityId":1})

    ctx = %{
      headers: %{"x-ecwid-webhook-signature" => "lidx/4J5L2Pp4auvwGBp6DwPkpPmyVLI3oLB440X358="}
    }

    assert :ok = provider.verify_signature(body, ctx, "abcde123456789")

    assert :ok =
             provider.verify_signature(
               String.replace(body, "entityId\":1", "entityId\":2"),
               ctx,
               "abcde123456789"
             )

    assert {:error, :invalid_signature} =
             provider.verify_signature(
               String.replace(body, "1234567", "1234568"),
               ctx,
               "abcde123456789"
             )

    assert {:ok, "80aece08-40e8-4145-8764-6c2f0d38678"} =
             provider.event_identity(Jason.decode!(body))

    assert {:ok, "0"} = provider.event_identity(%{"eventId" => 0})
    assert {:ok, "17"} = provider.event_identity(%{"eventId" => 17})

    for payload <- [%{}, %{"eventId" => ""}, %{"eventId" => -1}, %{"eventId" => nil}] do
      assert {:error, :malformed_payload} = provider.event_identity(payload)
    end

    assert {:ok, :webhook} = provider.parse_event_type(Jason.decode!(body))
    assert {:error, :invalid_signature} = provider.verify_signature("{}", ctx, "abcde123456789")
  end

  test "HubSpot v3 method/decoded URI/body/millisecond timestamp preserves the published Java answer" do
    # https://developers.hubspot.com/docs/apps/legacy-apps/authentication/validating-requests
    provider = Docs.compile("upgrade-crm-events-provider")
    ctx = %{
      headers: %{
        "x-hubspot-signature-v3" => @vector_signature,
        "x-hubspot-request-timestamp" => @vector_timestamp
      },
      method: @vector_method,
      request_uri: @vector_uri,
      now_ms: @vector_now_ms
    }

    assert :ok = provider.verify_signature(@vector_body, ctx, @vector_secret)

    assert {:error, :invalid_signature} =
             provider.verify_signature(@vector_body <> " ", ctx, @vector_secret)

    assert {:error, :stale_timestamp} =
             provider.verify_signature(
               @vector_body,
               %{ctx | now_ms: ctx.now_ms + 301_000},
               @vector_secret
             )

    encoded = "%3A%2f%3F%40%21%24%27%28%29%2A%2c%3B%20"
    assert provider.decode_request_uri(encoded) == ":/?@!$'()*,;%20"
    assert_batch_contract!(provider)
  end

  test "Twilio host URL/form canonicalizer preserves all three published Python SDK answers" do
    # https://www.twilio.com/docs/usage/webhooks/webhooks-security
    # https://github.com/twilio/twilio-python/blob/main/tests/unit/test_request_validator.py
    provider = Docs.compile("upgrade-messages-provider")
    uri = "https://mycompany.com/myapp.php?foo=1&bar=2"

    for {body, url, signature} <- [
          {"CallSid=CA1234567890ABCDE&Digits=1234&From=%2B14158675309&To=%2B18005551212&Caller=%2B14158675309",
           uri, "RSOYDt4T1cUTdK1PDd93/VVr8B8="},
          {"Sid=CA123&SidAccount=AC123&Digits=5678&Digits=1234&Digits=1234", uri,
           "IK+Dwps556ElfBT0I3Rgjkr1wJU="},
          {~s({"property": "value", "boolean": true}),
           uri <> "&bodySHA256=0a1ff7634d9ab3b95db5c9a2dfe9416e41502b283a80c7cf19632632f96e6620",
           "a9nBmqA0ju/hNViExpshrM61xv4="}
        ] do
      ctx = %{headers: %{"x-twilio-signature" => signature}, request_uri: url}
      assert :ok = provider.verify_signature(body, ctx, "12345")
      assert {:error, :invalid_signature} = provider.verify_signature(body <> "x", ctx, "12345")
    end

    assert_default_event!(provider)
    assert {:ok, %{"a" => "1", "b" => "2"}} = provider.decode_payload("b=2&a=1")
    assert {:ok, %{"id" => 1}} = provider.decode_payload(~s({"id":1}))
    decoder = fn _body -> {:ok, %{"from_host" => true}} end
    assert {:ok, %{"from_host" => true}} = provider.decode_payload("{}", decoder)
  end

  test "Standard Webhooks v1 and BigCommerce raw-key recipes preserve the published Go answer" do
    # https://github.com/standard-webhooks/standard-webhooks/tree/main/libraries/go
    # https://docs.bigcommerce.com/developer/docs/beta/webhooks/http-webhooks#webhook-signature
    body = ~s({"test": 2432232314})

    ctx = %{
      headers: %{
        "webhook-id" => "msg_p5jXN8AQM9LWM0D4loKWxJek",
        "webhook-timestamp" => "1614265330",
        "webhook-signature" => "v1,bad v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
      },
      now_ms: 1_614_265_330_000
    }

    replacement = Docs.compile("upgrade-commerce-events-provider")

    for {provider, key} <- [
          {Standard, "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"},
          {replacement, Base.decode64!("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")}
        ] do
      assert :ok = provider.verify_signature(body, ctx, key)
      assert {:error, :invalid_signature} = provider.verify_signature(body <> " ", ctx, key)

      assert {:error, :stale_timestamp} =
               provider.verify_signature(body, %{ctx | now_ms: ctx.now_ms + 301_000}, key)
    end

    assert_default_event!(replacement)
  end

  test "Standard Webhooks v1a recipe interoperates with the unchanged outbound signer" do
    # https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md
    # No published v1a envelope vector exists in this repository; RFC 8032 is pinned in scheme_test.
    {secret, public} = AshHooks.Signing.generate_signing_keypair()
    signature = AshHooks.Signing.sign_ed25519("m1", 1_700_000_000, "body", secret)

    ctx = %{
      headers: %{
        "webhook-id" => "m1",
        "webhook-timestamp" => "1700000000",
        "webhook-signature" => signature
      },
      now_ms: 1_700_000_000_000
    }

    assert :ok = StandardAsymmetric.verify_signature("body", ctx, public)
    assert {:error, :invalid_signature} = StandardAsymmetric.verify_signature("Body", ctx, public)
  end

  test "Magento RSA over base64 bytes and Wix JWS preserve algorithm and payload boundaries" do
    # https://developer.adobe.com/commerce/extensibility/webhooks/signature-verification
    # https://dev.wix.com/docs/build-apps/develop-your-app/api-integrations/events-and-webhooks/about-webhooks
    magento = Docs.compile("upgrade-commerce-rsa-provider")
    wix = Docs.compile("upgrade-site-tokens-provider")
    [entry] = :public_key.pem_decode(File.read!("test/fixtures/tls/server.key"))
    private = :public_key.pem_entry_decode(entry)
    key = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    body = ~s({"address":{"postcode":"50000"}})
    sig = :public_key.sign(Base.encode64(body), :sha256, private) |> Base.encode64()
    ctx = %{headers: %{"x-adobe-commerce-webhook-signature" => sig}}
    assert :ok = magento.verify_signature(body, ctx, key)
    assert {:error, :invalid_signature} = magento.verify_signature(body <> " ", ctx, key)
    modulus = @rfc_n |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
    rfc_key = {:RSAPublicKey, modulus, 65_537}
    assert :ok = wix.verify_signature(@rfc_jwt, %{now_ms: 1_300_819_379_000}, rfc_key)

    assert {:error, :stale_timestamp} =
             wix.verify_signature(@rfc_jwt, %{now_ms: 1_300_819_380_000}, rfc_key)

    assert {:error, :invalid_signature} = wix.verify_signature(@rfc_jwt <> "x", %{}, rfc_key)
    assert {:ok, claims} = wix.decode_payload(@rfc_jwt)
    assert claims["iss"] == "joe"
    assert wix.signature_source() == :body
    assert_default_event!(magento)
    assert_default_event!(wix)
    decoder = fn bytes -> Jason.decode(bytes) end
    assert {:ok, ^claims} = AshHooks.Provider.decode_payload(wix, @rfc_jwt, nil, decoder)
  end

  test "EasyPost v1 host-normalized secrets and v2 RFC 2822 timestamps use two configurations" do
    # https://docs.easypost.com/docs/webhooks#webhook-authentication
    # https://support.easypost.com/hc/en-us/articles/39826034964237-Webhook-HMAC-Validation
    provider = Docs.compile("upgrade-parcel-events-provider")
    body = ~s({"id":"evt_1","description":"tracker.updated"})

    for {key, mac} <- [
          {"test-key", "0b56c93f30784936100cc12e249dd143dbe61a42cea85c2e6cd3f718198d9c8c"},
          {"current-key", "f56153af3ad5caebb848c609d3352f626ef57ed4509b467be9b3c2a1f6ff6c85"},
          {"café-ﬁ-①", "def65090086adc634f026d5f3ef9ae51633f78b0e466d360636fc35d7af0cd75"}
        ] do
      ctx = %{headers: %{"x-hmac-signature" => "hmac-sha256-hex=" <> mac}}
      assert :ok = provider.verify_signature(body, ctx, key)
      assert {:error, :invalid_signature} = provider.verify_signature(body <> " ", ctx, key)
    end

    ctx = %{
      headers: %{
        "x-hmac-signature-v2" =>
          "HMAC-SHA256-HEX=1fcd868bb12771f13b80c413adbbc772f83bbd99b433f10f78dbe8454dfb32ee",
        "x-timestamp" => "Tue, 19 Aug 2025 20:37:09 -0000"
      },
      method: "POST",
      request_uri: "https://hooks.example.test/webhook/test",
      now_ms: 1_755_635_829_000
    }

    assert :ok = provider.verify_signature(~s({"event":"tracker.created"}), ctx, "test-key")

    assert {:error, :invalid_signature} =
             provider.verify_signature(~s({"event":"tracker.changed"}), ctx, "test-key")

    assert {:error, :stale_timestamp} =
             provider.verify_signature(
               ~s({"event":"tracker.created"}),
               %{ctx | now_ms: ctx.now_ms + 61_000},
               "test-key"
             )

    assert_default_event!(provider)

    v1_ctx = %{
      headers: %{
        "x-hmac-signature" =>
          "hmac-sha256-hex=0b56c93f30784936100cc12e249dd143dbe61a42cea85c2e6cd3f718198d9c8c"
      }
    }

    for v2 <- ["", "invalid"] do
      headers = Map.put(v1_ctx.headers, "x-hmac-signature-v2", v2)

      assert {:error, :invalid_signature} =
               provider.verify_signature(body, %{v1_ctx | headers: headers}, "test-key")
    end
  end

  test "a one-byte upgrade configuration mutation fails the known-answer runner" do
    block = Docs.block("upgrade-identity-checks-provider")
    mutated = String.replace(block.code, "complycube-signature", "complycube-signaturf")
    assert byte_size(mutated) == byte_size(block.code)

    bytes = Enum.zip(:binary.bin_to_list(block.code), :binary.bin_to_list(mutated))
    assert Enum.count(bytes, fn {original, changed} -> original != changed end) == 1

    namespace = Module.concat(__MODULE__, MutatedUpgrade)
    ast = Code.string_to_quoted!(mutated)

    quote do
      defmodule unquote(namespace) do
        unquote(ast)
      end
    end
    |> Docs.lexical()
    |> Code.compile_quoted(block.file)

    provider = Module.concat(namespace, MyApp.Webhooks.IdentityChecks)

    assert_raise ExUnit.AssertionError, fn -> assert_body_hmac_answer!(provider) end
  end

  defp assert_body_hmac_answer!(provider) do
    ctx = %{
      headers: %{
        "complycube-signature" =>
          "bc00414fa4d54277a3ed01e5ee258d9800a918a7791c7cda16d38b82f38f2150"
      }
    }

    assert :ok = provider.verify_signature(~s({"id":"value"}), ctx, "a_webhook_signature")
  end

  defp assert_default_event!(provider) do
    payload = %{"id" => "event-1", "type" => "sender.name"}
    assert {:ok, :webhook} = provider.parse_event_type(payload)

    assert {:ok, %AshHooks.Provider.Event{type: :webhook, payload: ^payload}} =
             provider.handle_event(:webhook, payload)

    assert_raw_identity!(provider)
  end

  defp assert_raw_identity!(provider) do
    assert :not_supported = AshHooks.Provider.event_identity(provider, %{"id" => "event-1"})
  end

  defp assert_batch_contract!(provider) do
    for {raw, type} <- subscription_types() do
      payload = [%{"subscriptionType" => raw}]
      assert {:ok, ^type} = provider.parse_event_type(payload)

      assert {:ok, %AshHooks.Provider.Event{type: ^type, payload: ^payload}} =
               provider.handle_event(type, payload)
    end

    for payload <- [[], %{}, [nil], [%{}], [%{"subscriptionType" => nil}]] do
      assert {:error, :malformed_payload} = provider.parse_event_type(payload)
      assert {:error, :malformed_payload} = provider.event_identity(payload)
    end

    assert {:error, :unknown_event_type} =
             provider.parse_event_type([%{"subscriptionType" => "new.type"}])

    events = [
      %{
        "subscriptionType" => "contact.creation",
        "eventId" => 1,
        "attemptNumber" => 0,
        "data" => %{"z" => 2, "a" => [1, 2]}
      },
      %{"subscriptionType" => "deal.creation", "eventId" => 2, "attemptNumber" => 1}
    ]

    assert {:ok, :mixed} = provider.parse_event_type(events)
    assert {:ok, identity} = provider.event_identity(events)
    assert identity == "93f1162d72d345b23e144cbbd79d0ad5caccee274aa66b44fe2b09984f52167a"
    retry = events |> Enum.reverse() |> Enum.map(&Map.put(&1, "attemptNumber", 99))
    assert {:ok, ^identity} = provider.event_identity(retry)
    assert {:ok, repeated} = provider.event_identity(events ++ events)
    refute repeated == identity
    [first, last] = events
    changed = put_in(first, ["data", "a"], [2, 1])
    assert {:ok, nested_order} = provider.event_identity([changed, last])
    refute nested_order == identity
  end

  defp identity_check_types do
    %{
      "client.created" => :client_created,
      "client.updated" => :client_updated,
      "client.deleted" => :client_deleted,
      "document.created" => :document_created,
      "document.updated" => :document_updated,
      "document.updated.image_uploaded" => :document_updated_image_uploaded,
      "document.updated.image_deleted" => :document_updated_image_deleted,
      "document.deleted" => :document_deleted,
      "address.created" => :address_created,
      "address.updated" => :address_updated,
      "address.deleted" => :address_deleted,
      "check.pending" => :check_pending,
      "check.completed" => :check_completed,
      "check.completed.clear" => :check_completed_clear,
      "check.completed.attention" => :check_completed_attention,
      "check.completed.rejected" => :check_completed_rejected,
      "check.completed.match_confirmed" => :check_completed_match_confirmed,
      "check.monitoring.attention" => :check_monitoring_attention,
      "check.failed" => :check_failed,
      "check.updated" => :check_updated,
      "workflow.session.started" => :workflow_session_started,
      "workflow.session.cancelled" => :workflow_session_cancelled,
      "workflow.session.processing" => :workflow_session_processing,
      "workflow.session.completed" => :workflow_session_completed,
      "workflow.session.updated" => :workflow_session_updated
    }
  end

  defp subscription_types do
    %{
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
      "conversation.newMessage" => :conversation_new_message,
      "object.creation" => :object_creation,
      "object.deletion" => :object_deletion,
      "object.propertyChange" => :object_property_change,
      "object.associationChange" => :object_association_change,
      "object.restore" => :object_restore,
      "object.merge" => :object_merge
    }
  end
end
