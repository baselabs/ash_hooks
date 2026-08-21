defmodule AshHooks.Provider.MockTest do
  use ExUnit.Case, async: true

  alias AshHooks.Provider
  alias AshHooks.Provider.Mock

  # The Mock's accept tests compute the HMAC in-test: they prove the Mock
  # delegates to the default implementation with the right plumbing. Crypto
  # conformance itself is proven in ProviderTest against RFC 4231 vectors.
  @body ~s({"type":"checked","id":"evt_1"})
  @secret "mock-signing-secret"

  defp sign(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp ctx(signature) do
    %{
      signature: signature,
      headers: %{"x-mock-signature" => signature},
      method: "POST",
      request_uri: "/webhooks/mock"
    }
  end

  describe "verify_signature/3" do
    test "accepts a correctly signed body through the full ctx map" do
      assert :ok = Mock.verify_signature(@body, ctx(sign(@body, @secret)), @secret)
    end

    test "rejects a body whose FIRST byte was tampered" do
      signature = sign(@body, @secret)
      <<_first, rest::binary>> = @body
      tampered_body = <<?x, rest::binary>>

      assert {:error, :invalid_signature} =
               Mock.verify_signature(tampered_body, ctx(signature), @secret)
    end

    test "rejects a signature whose first hex char was tampered" do
      tampered = sign(@body, @secret) |> flip_first_char()

      assert {:error, :invalid_signature} = Mock.verify_signature(@body, ctx(tampered), @secret)
    end

    test "rejects a signature made with a different secret" do
      assert {:error, :invalid_signature} =
               Mock.verify_signature(@body, ctx(sign(@body, "other")), @secret)
    end
  end

  describe "parse_event_type/1" do
    test "resolves an existing atom from the payload type string" do
      assert {:ok, :checked} = Mock.parse_event_type(%{"type" => "checked"})
    end

    test "fails closed on unknown type strings (no atom creation from input)" do
      assert {:error, :unknown_event_type} =
               Mock.parse_event_type(%{"type" => "ash_hooks_no_such_type_qz7"})
    end

    test "accepts an atom type directly (non-JSON callers)" do
      assert {:ok, :checked} = Mock.parse_event_type(%{"type" => :checked})
    end

    test "malformed payloads error without raising" do
      assert {:error, :malformed_payload} = Mock.parse_event_type(%{})
      assert {:error, :malformed_payload} = Mock.parse_event_type(nil)
    end
  end

  describe "handle_event/2" do
    test "echoes a typed event struct" do
      payload = %{"type" => "checked", "id" => "evt_1"}

      assert {:ok, %Mock.Event{type: :checked, payload: ^payload}} =
               Mock.handle_event(:checked, payload)
    end
  end

  describe "behaviour conformance" do
    test "exports every required callback" do
      # behaviour_info(:callbacks) includes the optional callbacks; required =
      # callbacks minus the declared-optional set.
      required =
        Provider.behaviour_info(:callbacks) -- Provider.behaviour_info(:optional_callbacks)

      for {name, arity} <- required do
        assert function_exported?(Mock, name, arity),
               "Mock is missing required callback #{name}/#{arity}"
      end
    end

    test "does not implement the optional secret callbacks (app-level default)" do
      optional = Provider.behaviour_info(:optional_callbacks)

      for {name, arity} <- optional do
        refute function_exported?(Mock, name, arity),
               "Mock should exercise the optional-absent path for #{name}/#{arity}"
      end
    end
  end

  defp flip_first_char(<<first, rest::binary>>) do
    replacement = if first == ?a, do: ?b, else: ?a
    <<replacement, rest::binary>>
  end
end
