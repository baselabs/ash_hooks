defmodule AshHooks.Provider.VerifierContractTest do
  use ExUnit.Case, async: true

  alias AshHooks.Provider

  alias AshHooks.Provider.{
    BigCommerce,
    Ecwid,
    Event,
    Hmac,
    Magento2,
    Shippo,
    Shopify,
    Squarespace,
    Stripe,
    Twilio,
    Wix,
    WooCommerce
  }

  for verifier <- [
        BigCommerce,
        Ecwid,
        Hmac,
        Magento2,
        Shippo,
        Shopify,
        Squarespace,
        Stripe,
        Twilio,
        Wix,
        WooCommerce
      ] do
    test "#{inspect(verifier)} preserves payloads, never atomizes vendor names, and rejects malformed context" do
      verifier = unquote(verifier)
      payload = %{"type" => "a-vendor-type-not-in-the-atom-table", "nested" => [1, 2, 3]}
      assert {:ok, :webhook} = verifier.parse_event_type(payload)
      assert {:error, :malformed_payload} = verifier.parse_event_type(:malformed)

      assert {:ok, %Event{type: :webhook, payload: ^payload}} =
               verifier.handle_event(:webhook, payload)

      assert {:error, :invalid_signature} = verifier.verify_signature("{}", nil, "configured-key")

      expected =
        case verifier do
          Stripe -> "stripe-signature"
          Shippo -> "shippo-auth-signature"
          BigCommerce -> "webhook-timestamp"
          _ -> nil
        end

      assert Provider.timestamp_header(verifier) == expected
    end
  end

  test "Ecwid accepts numeric documented event IDs and refuses absent identities" do
    assert {:ok, "123"} = Ecwid.event_identity(%{"eventId" => 123})
    assert {:error, :malformed_payload} = Ecwid.event_identity(%{})
    assert {:error, :malformed_payload} = Ecwid.event_identity(%{"eventId" => ""})

    assert {:error, :invalid_signature} =
             Shopify.verify_signature(nil, %{signature: "present"}, "key")
  end

  test "Wix's decoder and direct verifier contain malformed envelopes" do
    assert {:error, :invalid_signature} = Wix.decode_payload("not.a.jwt")
    # Deliberately invalid JWT fixture; exact scanner fingerprint is allowlisted.
    token = "eyJhbGciOiJSUzI1NiJ9.e30.invalid"

    assert {:error, :invalid_signature} =
             Wix.verify_signature(
               token,
               %{},
               "-----BEGIN PUBLIC KEY-----\nYQ==\n-----END PUBLIC KEY-----"
             )
  end
end
