defmodule AshHooks.Provider.SchemeRecipesTest do
  use ExUnit.Case, async: true
  alias AshHooks.Provider.Signature

  @rfc_n "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ"
  @rfc_jwt "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw"
  @vector_secret "cfc68c0b-4b4e-4ef8-b764-95350e4ea479"
  @vector_method "POST"
  @vector_uri "https://webhook.site/335453f5-94b3-49d9-b684-a55354d4b8df"
  @vector_body ~s([{"eventId":531833541,"subscriptionId":3923621,"portalId":48807704,"appId":16111050,"occurredAt":1752613920733,"subscriptionType":"contact.creation","attemptNumber":0,"objectId":138017612137,"changeFlag":"CREATED","changeSource":"CRM_UI","sourceId":"userId:76023669"}])
  @vector_timestamp "1752613922216"
  @vector_signature "gbj1XPRvUt0noT7i7fXfTzOD4sLzQmf0VT28ZYq0EYg="
  @vector_now_ms 1_752_613_922_216

  defmodule ComplyCube do
    use AshHooks.Provider,
      verify: [algorithm: :hmac_sha256, signature: {:header, "complycube-signature"}]
  end

  defmodule GitHub do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "x-hub-signature-256", prefix: "sha256="}
      ]
  end

  defmodule Shopify do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "x-shopify-hmac-sha256"},
        encoding: :base64
      ]
  end

  defmodule WooCommerce do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "x-wc-webhook-signature"},
        encoding: :base64
      ]
  end

  defmodule Stripe do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:structured_header, "stripe-signature", signature_key: "v1"},
        timestamp: {:signature_field, "t"},
        signed_input: [:timestamp, ".", :body]
      ]
  end

  defmodule Shippo do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:structured_header, "shippo-auth-signature", signature_key: "v1"},
        timestamp: {:signature_field, "t"},
        signed_input: [:timestamp, ".", :body]
      ]
  end

  defmodule Squarespace do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "squarespace-signature"},
        key_encoding: :hex
      ]
  end

  defmodule Ecwid do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "x-ecwid-webhook-signature"},
        encoding: :base64,
        signed_input: {AshHooks.Provider.SchemeRecipesTest, :ecwid_input}
      ]
  end

  defmodule HubSpot do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "x-hubspot-signature-v3"},
        encoding: :base64,
        signed_input: {AshHooks.Provider.SchemeRecipesTest, :hubspot_input},
        timestamp: {:header, "x-hubspot-request-timestamp"},
        timestamp_unit: :milliseconds
      ]
  end

  defmodule Twilio do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha1,
        signature: {:header, "x-twilio-signature"},
        encoding: :base64,
        signed_input: {AshHooks.Provider.SchemeRecipesTest, :twilio_input}
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

  defmodule BigCommerce do
    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature:
          {:structured_header, "webhook-signature",
           signature_key: "v1", pair_separator: " ", key_value_separator: ","},
        encoding: :base64,
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

  defmodule Magento do
    use AshHooks.Provider,
      verify: [
        algorithm: :rsa_pkcs1_sha256,
        signature: {:header, "x-adobe-commerce-webhook-signature"},
        signed_input: [{:base64, :body}]
      ]
  end

  defmodule Wix do
    use AshHooks.Provider, verify: [algorithm: :rsa_pkcs1_sha256, signature: :jws_body]
  end

  defmodule EasyPost do
    alias AshHooks.Provider.Scheme

    use AshHooks.Provider,
      verify: [
        algorithm: :hmac_sha256,
        signature: {:header, "x-hmac-signature", prefix: "hmac-sha256-hex="}
      ]

    @impl true
    def verify_signature(body, ctx, key) do
      if Enum.any?(ctx.headers, fn {name, _} -> String.downcase(name) == "x-hmac-signature-v2" end) do
        Scheme.verify(body, ctx, key,
          algorithm: :hmac_sha256,
          signature: {:header, "x-hmac-signature-v2", prefix: "hmac-sha256-hex="},
          encoding: :hex_any,
          signed_input: [{:header, "x-timestamp"}, :method, :path, :body],
          timestamp: {AshHooks.Provider.SchemeRecipesTest, :rfc2822_timestamp},
          tolerance_seconds: 60
        )
      else
        super(body, ctx, :unicode.characters_to_nfkd_binary(key))
      end
    end
  end

  test "ComplyCube lowercase hex body HMAC preserves the published PHP SDK answer" do
    # https://docs.complycube.com/documentation/webhooks
    ctx = %{
      headers: %{
        "complycube-signature" =>
          "bc00414fa4d54277a3ed01e5ee258d9800a918a7791c7cda16d38b82f38f2150"
      }
    }

    assert :ok = ComplyCube.verify_signature(~s({"id":"value"}), ctx, "a_webhook_signature")

    assert {:error, :invalid_signature} =
             ComplyCube.verify_signature(~s({"id":"Value"}), ctx, "a_webhook_signature")
  end

  test "Shopify and WooCommerce base64 body HMAC preserve Shopify's SDK known answer" do
    # https://shopify.dev/docs/apps/build/webhooks/verify-deliveries
    # https://woocommerce.com/document/webhooks/#webhook-delivery
    # https://github.com/Shopify/shopify-api-js/blob/main/packages/shopify-api/lib/webhooks/__tests__/validate.test.ts
    for {provider, header} <- [
          {Shopify, "x-shopify-hmac-sha256"},
          {WooCommerce, "x-wc-webhook-signature"}
        ] do
      ctx = %{headers: %{header => "B23tXN681gZ0qIWNRrgtzBE9XSDo5yaUu6wfmhu3a7g="}}
      assert :ok = provider.verify_signature(~s({"foo": "bar"}), ctx, "test_secret_key")

      assert {:error, :invalid_signature} =
               provider.verify_signature(~s({"foo": "baz"}), ctx, "test_secret_key")
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

    for {provider, header} <- [{Stripe, "stripe-signature"}, {Shippo, "shippo-auth-signature"}] do
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
    end
  end

  test "Squarespace hex key recipe preserves the independent known answer" do
    # https://commerce-apis.squarespace.com/webhooks/verifying-notifications
    body = ~s({"id":"evt_1","type":"order.created"})

    ctx = %{
      headers: %{
        "squarespace-signature" =>
          "12b0172d33523547e4f806a5e4612133fc21bf99237987639de5c1f8ea320813"
      }
    }

    assert :ok = Squarespace.verify_signature(body, ctx, "abcdef0123456789")

    assert {:error, :invalid_signature} =
             Squarespace.verify_signature(body <> " ", ctx, "abcdef0123456789")
  end

  test "Ecwid host canonicalization binds eventCreated.eventId and leaves entity data unsigned" do
    # https://github.com/Ecwid/ecwid-api-docs/blob/master/includes/_webhooks.md#webhooks-security
    body =
      ~s({"eventId":"80aece08-40e8-4145-8764-6c2f0d38678","eventCreated":1234567,"entityId":1})

    ctx = %{
      headers: %{"x-ecwid-webhook-signature" => "lidx/4J5L2Pp4auvwGBp6DwPkpPmyVLI3oLB440X358="}
    }

    assert :ok = Ecwid.verify_signature(body, ctx, "abcde123456789")

    assert :ok =
             Ecwid.verify_signature(
               String.replace(body, "entityId\":1", "entityId\":2"),
               ctx,
               "abcde123456789"
             )

    assert {:error, :invalid_signature} =
             Ecwid.verify_signature(
               String.replace(body, "1234567", "1234568"),
               ctx,
               "abcde123456789"
             )
  end

  test "HubSpot v3 method/decoded URI/body/millisecond timestamp preserves the published Java answer" do
    # https://developers.hubspot.com/docs/apps/legacy-apps/authentication/validating-requests
    ctx = %{
      headers: %{
        "x-hubspot-signature-v3" => @vector_signature,
        "x-hubspot-request-timestamp" => @vector_timestamp
      },
      method: @vector_method,
      request_uri: @vector_uri,
      now_ms: @vector_now_ms
    }

    assert :ok = HubSpot.verify_signature(@vector_body, ctx, @vector_secret)

    assert {:error, :invalid_signature} =
             HubSpot.verify_signature(@vector_body <> " ", ctx, @vector_secret)

    assert {:error, :stale_timestamp} =
             HubSpot.verify_signature(
               @vector_body,
               %{ctx | now_ms: ctx.now_ms + 301_000},
               @vector_secret
             )

    encoded = "%3A%2f%3F%40%21%24%27%28%29%2A%2c%3B%20"
    assert hubspot_uri(encoded) == ":/?@!$'()*,;%20"
  end

  test "Twilio host URL/form canonicalizer preserves all three published Python SDK answers" do
    # https://www.twilio.com/docs/usage/webhooks/webhooks-security
    # https://github.com/twilio/twilio-python/blob/main/tests/unit/test_request_validator.py
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
      assert :ok = Twilio.verify_signature(body, ctx, "12345")
      assert {:error, :invalid_signature} = Twilio.verify_signature(body <> "x", ctx, "12345")
    end
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

    for {provider, key} <- [
          {Standard, "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"},
          {BigCommerce, Base.decode64!("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")}
        ] do
      assert :ok = provider.verify_signature(body, ctx, key)
      assert {:error, :invalid_signature} = provider.verify_signature(body <> " ", ctx, key)

      assert {:error, :stale_timestamp} =
               provider.verify_signature(body, %{ctx | now_ms: ctx.now_ms + 301_000}, key)
    end
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
    [entry] = :public_key.pem_decode(File.read!("test/fixtures/tls/server.key"))
    private = :public_key.pem_entry_decode(entry)
    key = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    body = ~s({"address":{"postcode":"50000"}})
    sig = :public_key.sign(Base.encode64(body), :sha256, private) |> Base.encode64()
    ctx = %{headers: %{"x-adobe-commerce-webhook-signature" => sig}}
    assert :ok = Magento.verify_signature(body, ctx, key)
    assert {:error, :invalid_signature} = Magento.verify_signature(body <> " ", ctx, key)
    modulus = @rfc_n |> Base.url_decode64!(padding: false) |> :binary.decode_unsigned()
    rfc_key = {:RSAPublicKey, modulus, 65_537}
    assert :ok = Wix.verify_signature(@rfc_jwt, %{now_ms: 1_300_819_379_000}, rfc_key)

    assert {:error, :stale_timestamp} =
             Wix.verify_signature(@rfc_jwt, %{now_ms: 1_300_819_380_000}, rfc_key)

    assert {:error, :invalid_signature} = Wix.verify_signature(@rfc_jwt <> "x", %{}, rfc_key)
    assert {:ok, claims} = Wix.decode_payload(@rfc_jwt)
    assert claims["iss"] == "joe"
  end

  test "EasyPost v1 host-normalized secrets and v2 RFC 2822 timestamps use two configurations" do
    # https://docs.easypost.com/docs/webhooks#webhook-authentication
    # https://support.easypost.com/hc/en-us/articles/39826034964237-Webhook-HMAC-Validation
    body = ~s({"id":"evt_1","description":"tracker.updated"})

    for {key, mac} <- [
          {"test-key", "0b56c93f30784936100cc12e249dd143dbe61a42cea85c2e6cd3f718198d9c8c"},
          {"current-key", "f56153af3ad5caebb848c609d3352f626ef57ed4509b467be9b3c2a1f6ff6c85"},
          {"café-ﬁ-①", "def65090086adc634f026d5f3ef9ae51633f78b0e466d360636fc35d7af0cd75"}
        ] do
      ctx = %{headers: %{"x-hmac-signature" => "hmac-sha256-hex=" <> mac}}
      assert :ok = EasyPost.verify_signature(body, ctx, key)
      assert {:error, :invalid_signature} = EasyPost.verify_signature(body <> " ", ctx, key)
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

    assert :ok = EasyPost.verify_signature(~s({"event":"tracker.created"}), ctx, "test-key")

    assert {:error, :invalid_signature} =
             EasyPost.verify_signature(~s({"event":"tracker.changed"}), ctx, "test-key")

    assert {:error, :stale_timestamp} =
             EasyPost.verify_signature(
               ~s({"event":"tracker.created"}),
               %{ctx | now_ms: ctx.now_ms + 61_000},
               "test-key"
             )
  end

  def ecwid_input(body, _) do
    %{"eventCreated" => timestamp, "eventId" => id} = Jason.decode!(body)
    to_string(timestamp) <> "." <> to_string(id)
  end

  def hubspot_input(body, ctx),
    do:
      ctx.method <>
        hubspot_uri(ctx.request_uri) <>
        body <> Signature.header(ctx, "x-hubspot-request-timestamp")

  def hubspot_uri(uri) do
    Enum.reduce(
      Enum.zip(~w(3A 2F 3F 40 21 24 27 28 29 2A 2C 3B), [
        ":",
        "/",
        "?",
        "@",
        "!",
        "$",
        "'",
        "(",
        ")",
        "*",
        ",",
        ";"
      ]),
      uri,
      fn {hex, char}, acc ->
        acc
        |> String.replace("%" <> hex, char)
        |> String.replace("%" <> String.downcase(hex), char)
      end
    )
  end

  def twilio_input(body, ctx) do
    {:ok, %URI{scheme: scheme, host: host, query: query}} = URI.new(ctx.request_uri)
    true = scheme in ["http", "https"] and is_binary(host) and host != ""

    case for({"bodySHA256", hash} <- URI.query_decoder(query || ""), do: hash) do
      [] ->
        suffix =
          body
          |> URI.query_decoder()
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {key, values} -> Enum.map(Enum.sort(Enum.uniq(values)), &[key, &1]) end)
          |> IO.iodata_to_binary()

        ctx.request_uri <> suffix

      [hash] ->
        :ok =
          Signature.compare(
            Base.encode16(:crypto.hash(:sha256, body), case: :lower),
            hash
          )

        ctx.request_uri
    end
  end

  def rfc2822_timestamp(_, ctx) do
    # httpd_util uses numeric offsets and returns UTC seconds since year zero.
    case :httpd_util.convert_request_date(String.to_charlist(ctx.headers["x-timestamp"])) do
      {{_, _, _}, {_, _, _}} = datetime ->
        {:ok, :calendar.datetime_to_gregorian_seconds(datetime) - 62_167_219_200}

      _ ->
        :error
    end
  end
end
