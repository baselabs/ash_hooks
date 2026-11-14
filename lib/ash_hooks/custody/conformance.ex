defmodule AshHooks.Custody.Conformance do
  @moduledoc """
  An ExUnit case template for implementations of `AshHooks.Custody`.

  Use this module in a test module with `custodian: YourCustodian`. Add an
  ExUnit `setup` callback that provides a fresh real custody store before
  each test and registers its cleanup with `on_exit`. Callbacks use their
  normal public arities; configure any store connection in that setup.
  The template defaults to synchronous execution and forwards ExUnit case
  options such as `:async` and `:register`.

  To tag the generated tests, use `ExUnit.Case` and set `@moduletag` before
  using this template, which registers the tests when it expands.

  Tests cover kind bounds and assertions, idempotence, global tenant binding,
  permanent tombstones, concurrent store/destroy ordering, signing and
  verification, and literal fingerprint vectors. MAC corruption and truncation
  are checked by result, never by unreliable timing measurements. Passing
  these tests does not establish a backend's timing properties.

  ExUnit references expand only in the consumer's test module. This module
  compiles without ExUnit, so ExUnit is not a runtime dependency of ash_hooks.
  """

  @doc false
  defmacro __using__(opts) do
    custodian = Keyword.fetch!(opts, :custodian)
    case_opts = Keyword.take(opts, [:async, :group, :parameterize, :register])

    quote do
      use ExUnit.Case, unquote(case_opts)

      @custody_custodian unquote(custodian)
      @custody_material :binary.list_to_bin(Enum.to_list(0..31))
      @custody_kinds [
        {:standard_webhooks, :v1},
        {:standard_webhooks, :v1a},
        {:sender_hmac, :sha1},
        {:sender_hmac, :sha256},
        {:sender_hmac, :sha384},
        {:sender_hmac, :sha512},
        {:legacy_hmac, :sha256}
      ]

      unquote(bounds_tests())
      unquote(kind_tests())
      unquote(signature_tests())
      unquote(fingerprint_tests())
      unquote(destruction_tests())
      unquote(tenant_tests())
      unquote(concurrency_tests())
      unquote(signing_helpers())
      unquote(helpers())
    end
  end

  defp bounds_tests do
    quote do
      for {kind, accepted, rejected} <- [
            {{:standard_webhooks, :v1}, [24, 32, 64], [0, 1, 23, 65]},
            {{:standard_webhooks, :v1a}, [32], [0, 31, 33]},
            {{:sender_hmac, :sha1}, [1, 32, 16_384], [0, 16_385]},
            {{:sender_hmac, :sha256}, [1, 32, 16_384], [0, 16_385]},
            {{:sender_hmac, :sha384}, [1, 32, 16_384], [0, 16_385]},
            {{:sender_hmac, :sha512}, [1, 32, 16_384], [0, 16_385]},
            {{:legacy_hmac, :sha256}, [1, 32, 16_385, 32_768], [0]}
          ] do
        @custody_kind kind
        @custody_accepted accepted
        @custody_rejected rejected

        test "custody kind bounds #{inspect(kind)}" do
          for size <- @custody_accepted do
            assert :ok =
                     @custody_custodian.store(
                       custody_ref(),
                       :binary.copy(<<1>>, size),
                       nil,
                       @custody_kind
                     )
          end

          for size <- @custody_rejected do
            assert {:error, :invalid_material} =
                     @custody_custodian.store(
                       custody_ref(),
                       :binary.copy(<<1>>, size),
                       nil,
                       @custody_kind
                     )
          end
        end
      end
    end
  end

  defp kind_tests do
    quote do
      test "custody kind is asserted before every cryptographic operation" do
        for kind <- @custody_kinds do
          ref = custody_ref()
          assert :ok = @custody_custodian.store(ref, @custody_material, nil, kind)

          for other <- @custody_kinds -- [kind] do
            assert {:error, :kind_mismatch} = @custody_custodian.sign(ref, nil, other, "input")

            assert {:error, :kind_mismatch} =
                     @custody_custodian.verify(ref, nil, other, "input", <<>>)

            assert {:error, :kind_mismatch} = @custody_custodian.public_key(ref, nil, other)
            assert {:error, :kind_mismatch} = @custody_custodian.fingerprint(ref, nil, other)
          end
        end
      end

      test "custody store is idempotent only for the exact ref, material, kind, and tenant" do
        for kind <- @custody_kinds, tenant <- [nil, "tenant-a", "tenant-b"] do
          ref = custody_ref()
          assert :ok = @custody_custodian.store(ref, @custody_material, tenant, kind)
          assert :ok = @custody_custodian.store(ref, @custody_material, tenant, kind)

          assert {:error, :ref_exists} =
                   @custody_custodian.store(ref, :binary.copy(<<2>>, 32), tenant, kind)

          other_kind =
            if kind == {:standard_webhooks, :v1},
              do: {:standard_webhooks, :v1a},
              else: {:standard_webhooks, :v1}

          assert {:error, :ref_exists} =
                   @custody_custodian.store(ref, @custody_material, tenant, other_kind)

          assert {:error, :ref_exists} =
                   @custody_custodian.store(ref, @custody_material, "other-tenant", kind)
        end
      end
    end
  end

  defp signature_tests do
    quote do
      test "custody sign and verify use full signatures and reject last-byte corruption and truncation" do
        for kind <- @custody_kinds do
          ref = custody_ref()
          input = "exact\0input bytes"
          assert :ok = @custody_custodian.store(ref, @custody_material, "tenant-a", kind)

          mac = custody_assert_signing(kind, ref, input)

          assert :ok = @custody_custodian.verify(ref, "tenant-a", kind, input, mac)
          size = byte_size(mac) - 1
          <<prefix::binary-size(^size), last>> = mac
          corrupted = prefix <> <<Bitwise.bxor(last, 1)>>

          assert {:error, :invalid_signature} =
                   @custody_custodian.verify(ref, "tenant-a", kind, input, corrupted)

          assert {:error, :invalid_signature} =
                   @custody_custodian.verify(ref, "tenant-a", kind, input, prefix)

          assert {:error, :invalid_signature} =
                   @custody_custodian.verify(ref, "tenant-a", kind, input <> "!", mac)
        end
      end
    end
  end

  defp fingerprint_tests do
    quote do
      test "custody fingerprint matches literal spec vectors for both labels" do
        # Fixed key bytes and seed: 0 through 31. Expected digests were
        # computed independently from the documented domain-separated formula.
        for {kind, expected} <- [
              {{:standard_webhooks, :v1}, "BCC4F15252AD85C7428C00E5402DA269"},
              {{:standard_webhooks, :v1a}, "0854BD6BAD428AC29E6E346D31174875"}
            ] do
          ref = custody_ref()
          assert :ok = @custody_custodian.store(ref, @custody_material, nil, kind)
          expected = Base.decode16!(expected)
          assert {:ok, ^expected} = @custody_custodian.fingerprint(ref, nil, kind)
        end
      end

      test "custody has no fingerprint for every sender digest and legacy" do
        for kind <- Enum.reject(@custody_kinds, &match?({:standard_webhooks, _}, &1)) do
          ref = custody_ref()
          assert :ok = @custody_custodian.store(ref, @custody_material, nil, kind)
          assert {:error, :no_fingerprint} = @custody_custodian.fingerprint(ref, nil, kind)
        end
      end
    end
  end

  defp destruction_tests do
    quote do
      test "custody destroy is idempotent and permanently tombstones stored and never-stored refs" do
        for tenant <- [nil, "tenant-a"], kind <- @custody_kinds, stored? <- [true, false] do
          ref = custody_ref()

          if stored?,
            do: assert(:ok == @custody_custodian.store(ref, @custody_material, tenant, kind))

          assert :ok = @custody_custodian.destroy(ref, tenant)
          assert :ok = @custody_custodian.destroy(ref, tenant)
          assert {:error, :tenant_mismatch} = @custody_custodian.destroy(ref, "tenant-b")
          assert {:error, :ref_destroyed} = @custody_custodian.store(ref, <<>>, tenant, kind)

          for next_tenant <- [tenant, "tenant-b"] do
            assert {:error, :ref_destroyed} =
                     @custody_custodian.store(ref, @custody_material, next_tenant, kind)

            custody_assert_unknown(ref, next_tenant, kind)
          end
        end
      end
    end
  end

  defp tenant_tests do
    quote do
      test "custody absent refs and wrong-tenant refs never disclose existence or compute" do
        for kind <- @custody_kinds,
            {tenant, other} <- [{"tenant-a", "tenant-b"}, {nil, "tenant-a"}, {"tenant-a", nil}] do
          ref = custody_ref()
          custody_assert_unknown(ref, tenant, kind)
          assert :ok = @custody_custodian.store(ref, @custody_material, tenant, kind)
          custody_assert_unknown(ref, other, kind)
          custody_assert_unknown(ref, other, {:standard_webhooks, :v1a})

          assert {:error, :ref_exists} =
                   @custody_custodian.store(ref, @custody_material, other, kind)

          assert {:error, :tenant_mismatch} = @custody_custodian.destroy(ref, other)
          expected = custody_signature(kind, "input")
          assert :ok = @custody_custodian.verify(ref, tenant, kind, "input", expected)
        end
      end

      test "custody destroy under A then store under B returns ref_destroyed" do
        ref = custody_ref()
        assert :ok = @custody_custodian.destroy(ref, "tenant-a")

        assert {:error, :ref_destroyed} =
                 @custody_custodian.store(
                   ref,
                   @custody_material,
                   "tenant-b",
                   {:standard_webhooks, :v1}
                 )

        assert {:error, :tenant_mismatch} = @custody_custodian.destroy(ref, "tenant-b")
        assert :ok = @custody_custodian.destroy(ref, "tenant-a")
      end

      test "custody destroy under B of an absent ref then store under A returns ref_destroyed" do
        ref = custody_ref()
        assert :ok = @custody_custodian.destroy(ref, "tenant-b")

        assert {:error, :ref_destroyed} =
                 @custody_custodian.store(
                   ref,
                   @custody_material,
                   "tenant-a",
                   {:standard_webhooks, :v1}
                 )

        assert {:error, :tenant_mismatch} = @custody_custodian.destroy(ref, "tenant-a")
        assert :ok = @custody_custodian.destroy(ref, "tenant-b")
      end

      test "custody store under A then destroy under B leaves A's key working" do
        ref = custody_ref()
        kind = {:standard_webhooks, :v1}
        assert :ok = @custody_custodian.store(ref, @custody_material, "tenant-a", kind)
        assert {:error, :tenant_mismatch} = @custody_custodian.destroy(ref, "tenant-b")
        assert {:ok, mac} = @custody_custodian.sign(ref, "tenant-a", kind, "input")
        assert :ok = @custody_custodian.verify(ref, "tenant-a", kind, "input", mac)
        assert :ok = @custody_custodian.store(ref, @custody_material, "tenant-a", kind)
      end
    end
  end

  defp concurrency_tests do
    quote do
      test "custody concurrent stores bind a ref globally to exactly one tenant" do
        ref = custody_ref()
        kind = {:standard_webhooks, :v1}

        tasks =
          for tenant <- ["tenant-a", "tenant-b"],
              do:
                Task.async(fn ->
                  {tenant, @custody_custodian.store(ref, @custody_material, tenant, kind)}
                end)

        results = Enum.map(tasks, &Task.await/1)
        assert [{winner, :ok}] = Enum.filter(results, fn {_, result} -> result == :ok end)

        assert [{loser, {:error, :ref_exists}}] =
                 Enum.reject(results, fn {_, result} -> result == :ok end)

        assert {:error, :tenant_mismatch} = @custody_custodian.destroy(ref, loser)
        assert {:ok, _} = @custody_custodian.sign(ref, winner, kind, "input")
      end

      test "custody concurrent store and destroy are linearizable across tenants" do
        for destroy_tenant <- ["tenant-a", "tenant-b"] do
          ref = custody_ref()
          kind = {:standard_webhooks, :v1}

          store =
            Task.async(fn ->
              @custody_custodian.store(ref, @custody_material, "tenant-a", kind)
            end)

          destroy = Task.async(fn -> @custody_custodian.destroy(ref, destroy_tenant) end)
          store_result = Task.await(store)
          destroy_result = Task.await(destroy)

          case {store_result, destroy_result} do
            {:ok, {:error, :tenant_mismatch}} ->
              assert destroy_tenant == "tenant-b"
              assert {:ok, _} = @custody_custodian.sign(ref, "tenant-a", kind, "input")

            {result, :ok} when result in [:ok, {:error, :ref_destroyed}] ->
              assert result != :ok or destroy_tenant == "tenant-a"

              assert {:error, :ref_destroyed} =
                       @custody_custodian.store(ref, @custody_material, "tenant-a", kind)

              custody_assert_unknown(ref, "tenant-a", kind)

            other ->
              flunk("non-linearizable custody results: #{inspect(other)}")
          end
        end
      end
    end
  end

  defp signing_helpers do
    quote do
      defp custody_assert_signing(kind, ref, input) do
        case kind do
          {:standard_webhooks, :v1a} ->
            {:ok, public} = @custody_custodian.public_key(ref, "tenant-a", kind)
            {expected_public, _} = :crypto.generate_key(:eddsa, :ed25519, @custody_material)
            assert public == expected_public
            {:ok, signature} = @custody_custodian.sign(ref, "tenant-a", kind, input)
            assert :crypto.verify(:eddsa, :none, input, signature, [public, :ed25519])
            signature

          {family, digest} ->
            digest = custody_digest(digest)
            expected = :crypto.mac(:hmac, digest, @custody_material, input)

            if family == :sender_hmac do
              assert {:error, :not_signable} =
                       @custody_custodian.sign(ref, "tenant-a", kind, input)
            else
              assert {:ok, ^expected} = @custody_custodian.sign(ref, "tenant-a", kind, input)
            end

            assert {:error, :no_public_half} =
                     @custody_custodian.public_key(ref, "tenant-a", kind)

            expected
        end
      end
    end
  end

  defp helpers do
    quote do
      defp custody_ref, do: "ahk_" <> Ash.UUIDv7.generate()

      defp custody_assert_unknown(ref, tenant, kind) do
        assert {:error, :unknown_ref} = @custody_custodian.sign(ref, tenant, kind, "input")

        assert {:error, :unknown_ref} =
                 @custody_custodian.verify(ref, tenant, kind, "input", <<>>)

        assert {:error, :unknown_ref} = @custody_custodian.public_key(ref, tenant, kind)
        assert {:error, :unknown_ref} = @custody_custodian.fingerprint(ref, tenant, kind)
      end

      defp custody_signature({:standard_webhooks, :v1a}, input),
        do: :crypto.sign(:eddsa, :none, input, [@custody_material, :ed25519])

      defp custody_signature({_, digest}, input) do
        digest = custody_digest(digest)
        :crypto.mac(:hmac, digest, @custody_material, input)
      end

      defp custody_digest(:v1), do: :sha256
      defp custody_digest(:sha1), do: :sha
      defp custody_digest(digest), do: digest
    end
  end
end
