defmodule AshHooks.Provider.VerifierContractTest do
  use ExUnit.Case, async: true
  alias AshHooks.Provider
  alias AshHooks.Provider.{Event, Hmac}

  defmodule Configured do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
  end

  for verifier <- [Hmac, Configured] do
    test "#{inspect(verifier)} preserves payloads and rejects malformed contexts" do
      verifier = unquote(verifier)
      payload = %{"type" => "an-event-name-never-atomized", "nested" => [1, 2, 3]}
      assert {:ok, :webhook} = verifier.parse_event_type(payload)
      assert {:error, :malformed_payload} = verifier.parse_event_type(:malformed)

      assert {:ok, %Event{type: :webhook, payload: ^payload}} =
               verifier.handle_event(:webhook, payload)

      assert {:error, :invalid_signature} = verifier.verify_signature("{}", nil, "configured-key")
      assert Provider.timestamp_header(verifier) == nil
    end
  end
end
