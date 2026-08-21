defmodule AshHooks.ProviderTest do
  use ExUnit.Case, async: true

  alias AshHooks.Provider

  @moduledoc false

  # Accept proofs use RFC 4231 known-answer vectors (fetched first-hand from
  # https://www.rfc-editor.org/rfc/rfc4231.txt) — provider-independent, never
  # self-signed. Rejection proofs (below) tamper values computed in-test: a
  # rejection test does not need provider provenance, only a real mismatch.
  @rfc4231_tc1_key String.duplicate("\x0B", 20)
  @rfc4231_tc1_data "Hi There"
  @rfc4231_tc1_sha256 "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
  @rfc4231_tc1_sha512 "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
  @rfc4231_tc2_key "Jefe"
  @rfc4231_tc2_data "what do ya want for nothing?"
  @rfc4231_tc2_sha256 "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
  @rfc4231_tc2_sha512 "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"

  describe "default_verify_signature/4 — RFC 4231 accept vectors" do
    test "hmac_sha256 test case 1" do
      assert :ok =
               Provider.default_verify_signature(
                 @rfc4231_tc1_data,
                 @rfc4231_tc1_sha256,
                 @rfc4231_tc1_key,
                 :hmac_sha256
               )
    end

    test "hmac_sha256 test case 2" do
      assert :ok =
               Provider.default_verify_signature(
                 @rfc4231_tc2_data,
                 @rfc4231_tc2_sha256,
                 @rfc4231_tc2_key,
                 :hmac_sha256
               )
    end

    test "hmac_sha512 test case 1" do
      assert :ok =
               Provider.default_verify_signature(
                 @rfc4231_tc1_data,
                 @rfc4231_tc1_sha512,
                 @rfc4231_tc1_key,
                 :hmac_sha512
               )
    end

    test "hmac_sha512 test case 2" do
      assert :ok =
               Provider.default_verify_signature(
                 @rfc4231_tc2_data,
                 @rfc4231_tc2_sha512,
                 @rfc4231_tc2_key,
                 :hmac_sha512
               )
    end
  end

  describe "default_verify_signature/4 — tamper negatives" do
    setup do
      body = ~s({"type":"checked","id":"evt_123"})
      secret = "tamper-test-secret"
      signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
      %{body: body, secret: secret, signature: signature}
    end

    test "rejects a body whose FIRST byte was tampered", %{
      body: body,
      secret: secret,
      signature: signature
    } do
      <<_first, rest::binary>> = body
      tampered_body = <<?x, rest::binary>>

      assert {:error, :invalid_signature} =
               Provider.default_verify_signature(tampered_body, signature, secret, :hmac_sha256)
    end

    test "rejects a signature whose first hex char was tampered", %{
      body: body,
      secret: secret,
      signature: signature
    } do
      tampered_signature = flip_first_char(signature)

      assert {:error, :invalid_signature} =
               Provider.default_verify_signature(body, tampered_signature, secret, :hmac_sha256)
    end

    test "rejects an uppercase-hex signature (canonical form is lowercase)", %{
      body: body,
      secret: secret,
      signature: signature
    } do
      assert {:error, :invalid_signature} =
               Provider.default_verify_signature(
                 body,
                 String.upcase(signature),
                 secret,
                 :hmac_sha256
               )
    end

    test "rejects wrong-length signatures", %{body: body, secret: secret, signature: signature} do
      for shortened <- [String.slice(signature, 0, 63), signature <> "0", ""] do
        assert {:error, :invalid_signature} =
                 Provider.default_verify_signature(body, shortened, secret, :hmac_sha256)
      end
    end

    test "rejects a signature made with a different secret", %{body: body, signature: signature} do
      assert {:error, :invalid_signature} =
               Provider.default_verify_signature(body, signature, "other-secret", :hmac_sha256)
    end
  end

  describe "constant-time compare tripwire (mutation-red gate)" do
    test "default_verify_signature compares via :crypto.hash_equals/2, never a bare ==" do
      {:ok, body} = fetch_default_verify_signature_body(provider_source_ast())

      assert calls_constant_time_compare?(body),
             "default_verify_signature must compare digests with :crypto.hash_equals/2"

      refute compares_header_with_bare_equality?(body),
             "default_verify_signature must not compare the header value with ==/!=/=:= directly"
    end

    test "the named mutation (:crypto.hash_equals -> ==) turns the tripwire red" do
      # Non-vacuity proof for the tripwire above: apply the exact mutation the
      # gate names and confirm the detector fails. hash_equals and == are
      # functionally equivalent on equal-length binaries (their deltas —
      # timing and the unequal-length raise — are neutralized by the byte_size
      # guard), so no behavioral test can distinguish them; pinning the
      # constant-time MECHANISM is the only deterministic red under this
      # mutation.
      mutated = mutate_hash_equals_to_equals(provider_source_ast())
      {:ok, body} = fetch_default_verify_signature_body(mutated)

      refute calls_constant_time_compare?(body)
      assert compares_header_with_bare_equality?(body)
    end
  end

  describe "secret_scope/1" do
    test "absent webhook_secret_scope/0 defaults to :app_level" do
      assert Provider.secret_scope(AshHooks.Provider.Mock) == :app_level
    end

    test "an implemented webhook_secret_scope/0 is honored" do
      defmodule PerConnectionProvider do
        @behaviour AshHooks.Provider

        def webhook_secret_scope, do: :per_connection
        def verify_signature(_raw_body, _ctx, _secret), do: :ok
        def parse_event_type(_payload), do: {:ok, :mock}
        def handle_event(_event_type, _payload), do: {:ok, %{}}
      end

      assert Provider.secret_scope(PerConnectionProvider) == :per_connection
    end
  end

  defp flip_first_char(<<first, rest::binary>>) do
    replacement = if first == ?a, do: ?b, else: ?a
    <<replacement, rest::binary>>
  end

  defp provider_source_ast do
    path = Path.expand("../../lib/ash_hooks/provider.ex", __DIR__)
    {:ok, ast} = Code.string_to_quoted(File.read!(path))
    ast
  end

  defp fetch_default_verify_signature_body(ast) do
    {_, acc} =
      Macro.prewalk(ast, :missing, fn
        {:def, _, [head, block]} = node, :missing ->
          if function_name(head) == :default_verify_signature do
            {node, {:ok, Keyword.fetch!(block, :do)}}
          else
            {node, :missing}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # A def with a `when` guard nests the call inside {:when, _, [call, guard]}.
  defp function_name({:when, _, [{name, _, _} | _]}), do: name
  defp function_name({name, _, _}), do: name

  defp calls_constant_time_compare?(body) do
    Macro.prewalk(body, false, fn
      {:., _, [:crypto, :hash_equals]} = node, _acc -> {node, true}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  defp compares_header_with_bare_equality?(body) do
    Macro.prewalk(body, false, fn
      {op, _, [lhs, rhs]} = node, acc when op in [:==, :!=] ->
        if match?({:header_value, _, _}, lhs) or match?({:header_value, _, _}, rhs) do
          {node, true}
        else
          {node, acc}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp mutate_hash_equals_to_equals(ast) do
    Macro.prewalk(ast, fn
      {{:., meta, [:crypto, :hash_equals]}, _call_meta, args} -> {:==, meta, args}
      node -> node
    end)
  end
end
