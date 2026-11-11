defmodule AshHooks.Provider.AdditionalVerifiersTest do
  use ExUnit.Case, async: true

  alias AshHooks.Provider.{BigCommerce, Ecwid, Shippo, Shopify, Squarespace, Stripe, WooCommerce}

  # Independent OpenSSL calculations of the documented schemes. These are unit
  # vectors, not claims of live provider acceptance. Complete keyed vendor
  # vectors were not published in the cited Shopify/WooCommerce/Shippo/Squarespace
  # guides. Shopify's SDK, Twilio's SDK, and Standard Webhooks also supply
  # complete published known answers below/in the dedicated tests.
  @body ~s({"id":"evt_1","type":"order.created"})
  @raw_signature "WaaUjLO7nDrBf3xZmRIz6spG00/QKXh/Lv59bU6VbQk="
  @timestamp_signature "14852ee51817599372538c265e8d14af52a5c81c9a7daa1424f386b1b0bb5913"

  for provider <- [Shopify, WooCommerce] do
    test "#{inspect(provider)} verifies exact-body base64 HMAC and rejects hostile inputs" do
      provider = unquote(provider)
      # Shopify's published SDK validate.test.ts vector with test-config.ts's key:
      # https://github.com/Shopify/shopify-api-js/blob/main/packages/shopify-api/lib/webhooks/__tests__/validate.test.ts
      assert :ok =
               provider.verify_signature(
                 ~s({"foo": "bar"}),
                 %{signature: "B23tXN681gZ0qIWNRrgtzBE9XSDo5yaUu6wfmhu3a7g="},
                 "test_secret_key"
               )

      assert :ok = provider.verify_signature(@body, %{signature: @raw_signature}, "test-key")

      assert {:error, :invalid_signature} =
               provider.verify_signature(@body <> " ", %{signature: @raw_signature}, "test-key")

      for signature <- [nil, "", <<255>>, String.duplicate("x", 80)] do
        assert {:error, :invalid_signature} =
                 provider.verify_signature(@body, %{signature: signature}, "test-key")
      end

      assert {:error, :no_webhook_secret} = provider.verify_signature(@body, %{}, "")
      assert {:ok, :webhook} = provider.parse_event_type(%{"type" => "never-create-an-atom"})
      assert {:ok, %AshHooks.Provider.Event{payload: %{}}} = provider.handle_event(:webhook, %{})
    end
  end

  for provider <- [Stripe, Shippo] do
    test "#{inspect(provider)} authenticates timestamp.body, rotates v1 entries, and enforces a replay window" do
      provider = unquote(provider)

      ctx = %{
        signature: "t=1700000000,v0=ignore,v1=bad,v1=" <> @timestamp_signature,
        now_ms: 1_700_000_000_000
      }

      assert :ok = provider.verify_signature(@body, ctx, "test-key")

      assert {:error, :invalid_signature} =
               provider.verify_signature(@body <> " ", ctx, "test-key")

      assert {:error, :stale_timestamp} =
               provider.verify_signature(@body, %{ctx | now_ms: ctx.now_ms + 301_000}, "test-key")

      assert {:error, :stale_timestamp} =
               provider.verify_signature(@body, %{ctx | now_ms: ctx.now_ms - 301_000}, "test-key")

      assert :ok =
               provider.verify_signature(
                 @body,
                 Map.put(%{ctx | now_ms: ctx.now_ms + 301_000}, :replay_window_seconds, 302),
                 "test-key"
               )

      assert {:error, :invalid_signature} =
               provider.verify_signature(
                 @body,
                 %{ctx | signature: "t=1700000000,v0=" <> @timestamp_signature},
                 "test-key"
               )

      assert {:error, :invalid_signature} =
               provider.verify_signature(
                 @body,
                 %{ctx | signature: ctx.signature <> ",t=1700000001"},
                 "test-key"
               )

      for signature <- [nil, "", <<255>>, "t=invalid,v1=bad"] do
        assert {:error, :invalid_signature} =
                 provider.verify_signature(@body, %{ctx | signature: signature}, "test-key")
      end

      assert {:error, :no_webhook_secret} = provider.verify_signature(@body, ctx, "")
    end
  end

  test "Squarespace hex-decodes its secret and compares a lowercase-hex digest" do
    ctx = %{signature: "12b0172d33523547e4f806a5e4612133fc21bf99237987639de5c1f8ea320813"}
    assert :ok = Squarespace.verify_signature(@body, ctx, "abcdef0123456789")
    assert {:error, :invalid_signature} = Squarespace.verify_signature(@body, ctx, "not-hex")

    assert {:error, :invalid_signature} =
             Squarespace.verify_signature(
               @body,
               %{ctx | signature: String.upcase(ctx.signature)},
               "abcdef0123456789"
             )

    assert {:error, :invalid_signature} =
             Squarespace.verify_signature(@body <> " ", ctx, "abcdef0123456789")

    assert {:error, :no_webhook_secret} = Squarespace.verify_signature(@body, ctx, "")
  end

  test "Ecwid signs only eventCreated.eventId; unsigned entity data is not authentication proof" do
    body =
      ~s({"eventId":"80aece08-40e8-4145-8764-6c2f0d38678","eventCreated":1234567,"entityId":1})

    ctx = %{signature: "lidx/4J5L2Pp4auvwGBp6DwPkpPmyVLI3oLB440X358="}
    assert :ok = Ecwid.verify_signature(body, ctx, "abcde123456789")

    assert :ok =
             Ecwid.verify_signature(
               String.replace(body, "\"entityId\":1", "\"entityId\":2"),
               ctx,
               "abcde123456789"
             )

    assert {:error, :invalid_signature} =
             Ecwid.verify_signature(
               String.replace(body, "1234567", "1234568"),
               ctx,
               "abcde123456789"
             )

    assert {:error, :invalid_signature} = Ecwid.verify_signature("[]", ctx, "abcde123456789")

    assert {:error, :invalid_signature} =
             Ecwid.verify_signature("not-json", ctx, "abcde123456789")

    assert {:error, :no_webhook_secret} = Ecwid.verify_signature(body, ctx, "")

    assert {:ok, "80aece08-40e8-4145-8764-6c2f0d38678"} =
             Ecwid.event_identity(Jason.decode!(body))
  end

  test "BigCommerce implements the vendor's Standard Webhooks contract with raw client-secret bytes" do
    # Published Standard Webhooks Go vector, used by the verifier BigCommerce
    # explicitly recommends; not a BigCommerce live-delivery fixture.
    headers = %{
      "webhook-id" => "msg_p5jXN8AQM9LWM0D4loKWxJek",
      "webhook-timestamp" => "1614265330",
      "webhook-signature" => "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
    }

    secret = Base.decode64!("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
    body = ~s({"test": 2432232314})
    ctx = %{signature: headers["webhook-signature"], headers: headers, now_ms: 1_614_265_330_000}
    assert :ok = BigCommerce.verify_signature(body, ctx, secret)
    assert {:error, :invalid_signature} = BigCommerce.verify_signature(body <> " ", ctx, secret)

    assert {:error, :invalid_signature} =
             BigCommerce.verify_signature(
               body,
               %{ctx | headers: Map.delete(headers, "webhook-id")},
               secret
             )

    assert {:error, :stale_timestamp} =
             BigCommerce.verify_signature(body, %{ctx | now_ms: ctx.now_ms + 301_000}, secret)

    assert {:error, :no_webhook_secret} = BigCommerce.verify_signature(body, ctx, "")
  end
end
