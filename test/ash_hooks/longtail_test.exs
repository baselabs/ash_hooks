defmodule AshHooks.LongTailTest do
  @moduledoc """
  Direct unit coverage for the small pure surfaces: error message/1
  clauses, the top-level entry points, event/legacy/signing edges, the
  SSRF classifier arms, the Ash.Type Ecto surfaces, CertSan's DER
  fallbacks, and the HubSpot v3 guard arms.
  """

  use ExUnit.Case, async: true

  alias AshHooks.Endpoint.{SecretRef, Url}
  alias AshHooks.Errors.Invalid
  alias AshHooks.Errors.Unknown
  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.Http.CertSan
  alias AshHooks.InboundDelivery.Payload
  alias AshHooks.Provider.HubSpotV3

  describe "error message/1 clauses" do
    test "every Invalid class renders its message" do
      assert Exception.message(%Invalid.InvalidSignature{}) ==
               "webhook signature verification failed"

      assert Exception.message(%Invalid.NoWebhookSecret{}) ==
               "no webhook signing secret configured"

      assert Exception.message(%Invalid.StaleTimestamp{}) ==
               "webhook timestamp is outside the replay window"

      assert Exception.message(Invalid.UnknownEventType.exception(event_type: "wat")) ==
               "unknown event type \"wat\""

      assert Exception.message(Invalid.MalformedPayload.exception(provider: :cc, detail: "bad")) ==
               "malformed webhook payload for provider :cc: bad"

      assert Exception.message(%Invalid.MalformedPayload{}) == "malformed webhook payload"
    end

    test "the error-class module answers its class" do
      assert Unknown.error_class?()
    end

    test "UnknownError passes through exception messages and inspects terms" do
      assert Exception.message(UnknownError.exception(error: %ArgumentError{message: "boom"})) ==
               "boom"

      assert Exception.message(UnknownError.exception(error: {:tuple, 1})) == "{:tuple, 1}"
    end
  end

  describe "top-level entry points" do
    test "AshHooks.dispatch/3 uses the default opts (delegate arity)" do
      assert_raise ArgumentError, ~r/not a Spark DSL module/, fn ->
        AshHooks.dispatch(AshHooks.LongTailTest, :nope, :not_an_event)
      end
    end

    test "validate_secret_source rejects garbage shapes" do
      assert {:error, message} = AshHooks.validate_secret_source(42)
      assert message =~ "invalid secret source"
    end
  end

  describe "Event.new edges" do
    test "a map of attrs builds like the keyword form" do
      assert {:ok, event} = AshHooks.Event.new(%{type: :order_paid, payload: ~s({"a": 1})})
      assert event.type == "order_paid"
    end

    test "an event without an id gets a generated msg_ id" do
      assert {:ok, event} = AshHooks.Event.new(type: :order_paid, payload: ~s({"a": 1}))
      assert String.starts_with?(event.id, "msg_")

      # the explicit id: nil takes the same generation arm
      assert {:ok, event2} = AshHooks.Event.new(id: nil, type: :order_paid, payload: ~s({"a": 1}))
      assert String.starts_with?(event2.id, "msg_")
    end
  end

  describe "Legacy.headers/4 default previous" do
    test "the 3-arity call signs with the incumbent only" do
      headers = AshHooks.Legacy.headers("incumbent-secret", ~s({"b": 2}), 1_700_000_000)

      assert {:ok, _} =
               AshHooks.Legacy.verify(
                 "incumbent-secret",
                 ~s({"b": 2}),
                 headers["x-webhook-signature"],
                 1_700_000_000
               )
    end
  end

  describe "Signing edges" do
    test "sign_ed25519 rejects a dot-bearing msg_id loudly" do
      whsk = elem(AshHooks.Signing.generate_signing_keypair(), 0)

      assert_raise ArgumentError, ~r/msg_id must not contain/, fn ->
        AshHooks.Signing.sign_ed25519("a.b", 1_700_000_000, "body", whsk)
      end
    end

    test "headers/4 with no secret material raises" do
      assert_raise ArgumentError, ~r/at least one/, fn ->
        AshHooks.Signing.headers("m1", 1_700_000_000, "body")
      end
    end

    test "a v1a signature that is not base64 fails verification, not the matcher" do
      {_whsk, whpk} = AshHooks.Signing.generate_signing_keypair()

      headers = %{
        "webhook-id" => "m1",
        "webhook-timestamp" => "1700000000",
        "webhook-signature" => "v1a,!!!not-base64!!!"
      }

      assert {:error, :invalid_signature} =
               AshHooks.Signing.verify("body", headers, whpk, now: 1_700_000_000)
    end

    test "an empty decoded secret is :invalid_secret" do
      headers = %{
        "webhook-id" => "m1",
        "webhook-timestamp" => "1700000000",
        "webhook-signature" => "v1a," <> Base.encode64(:crypto.strong_rand_bytes(64))
      }

      assert {:error, :invalid_secret} =
               AshHooks.Signing.verify("body", headers, "whsec_", now: 1_700_000_000)
    end
  end

  describe "Ssrf classifier arms" do
    test "non-http schemes, non-binaries, and hostless urls are :unsafe" do
      assert {:error, :unsafe} = AshHooks.Ssrf.resolve_public("ftp://example.com/x")
      assert {:error, :unsafe} = AshHooks.Ssrf.resolve_public(42)
      assert {:error, :unsafe} = AshHooks.Ssrf.resolve_public("http:///no-host")
    end

    test "cloud metadata hostnames are refused before resolution" do
      assert {:error, :unsafe} = AshHooks.Ssrf.resolve_public("http://metadata.google.internal/x")
    end

    test "non-binary inputs to registration_safe? are false" do
      refute AshHooks.Ssrf.registration_safe?(42)
    end

    test "IPv6 loopback and Teredo literals are not public" do
      assert {:error, :unsafe} = AshHooks.Ssrf.resolve_public("http://[::1]/x")
      assert {:error, :unsafe} = AshHooks.Ssrf.resolve_public("http://[2001:0::1]/x")
    end
  end

  describe "Ash.Type surfaces (direct)" do
    test "Endpoint.Url casts and refuses" do
      assert Url.cast_input(nil, []) == {:ok, nil}
      assert {:error, message} = Url.cast_input(42, [])
      assert message =~ "must be a URL string"
      assert Url.cast_stored(nil, []) == {:ok, nil}
      assert {:error, _} = Url.cast_stored(42, [])
      assert {:error, _} = Url.dump_to_native(42, [])
    end

    test "Endpoint.SecretRef casts and refuses" do
      assert {:error, _} = SecretRef.cast_input(42, [])
      assert {:error, _} = SecretRef.cast_stored(42, [])
      assert {:error, _} = SecretRef.dump_to_native(42, [])
    end

    test "InboundDelivery.Payload edge arms" do
      assert Payload.cast_stored(nil, []) == {:ok, nil}
      assert :error = Payload.cast_stored(42, [])
      assert :error = Payload.dump_to_native(42, [])
      assert {:ok, nil} = Payload.apply_constraints(nil, [])
    end
  end

  describe "the Ash.Type use-injected helpers" do
    test "the trivial 0-arity introspection surface answers" do
      for mod <- [
            AshHooks.Endpoint.Url,
            AshHooks.Endpoint.SecretRef,
            AshHooks.InboundDelivery.Payload
          ] do
        assert mod.ash_type?()
        refute mod.embedded?()
        assert mod.simple_equality?()
        assert is_atom(mod.ecto_type())
        assert is_list(mod.constraints())
        assert is_list(mod.array_constraints())
        assert is_atom(mod.storage_type(nil))
        assert mod.handle_change?() == false
        assert mod.prepare_change?() == false
        assert mod.custom_apply_constraints_array?() == false
        assert mod.simple_equality_comparable?() == false
        assert {:ok, nil} = mod.init(nil)
        assert mod.can_load?(nil) == false
        assert mod.cast_in_query?(nil) == true
        assert mod.composite?(nil) == false
        assert is_list(mod.composite_types(nil))
        assert is_binary(mod.describe(nil))
        assert is_boolean(mod.matches_type?(:any, :any))
      end
    end
  end

  describe "CertSan DER fallbacks" do
    test "garbage DER fails closed as a plain false, never a raise" do
      refute CertSan.ip_san_match?(<<1, 2, 3>>, {127, 0, 0, 1})
      refute CertSan.ip_san_match?(<<0>>, {127, 0, 0, 1})
    end
  end

  describe "HubSpot v3 guard arms" do
    test "verification without a v1-shaped signature fails closed" do
      assert {:error, :invalid_signature} =
               HubSpotV3.verify_signature(
                 "raw",
                 %{headers: %{}, signature: nil},
                 "s"
               )
    end

    test "non-secret and headerless-ctx shapes hit the guard catch-alls" do
      assert {:error, :invalid_signature} =
               HubSpotV3.verify_signature("raw", %{}, :not_a_secret)

      assert {:error, :invalid_signature} =
               HubSpotV3.verify_signature(
                 "raw",
                 %{signature: "v1=abc"},
                 "secret"
               )
    end
  end
end
