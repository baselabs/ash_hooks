defmodule AshHooks.HostExtensionDslTest do
  use ExUnit.Case, async: false

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.Test.Dsl
  alias Spark.Error.DslError

  defmodule NoBehaviour do
    def sign(_, _), do: :skip
  end

  defmodule ValidSigner do
    @behaviour AshHooks.Signer
    @impl true
    def sign(_, _), do: :skip
  end

  defmodule UnreadableType do
    use Ash.Type.NewType, subtype_of: :string

    @impl true
    def dump_to_embedded(_, _), do: raise("type cannot serialize embedded values")
  end

  test "Spark refuses a signer without its behaviour or without the callback" do
    assert_dsl_error(~r/signer must implement AshHooks.Signer/, fn ->
      endpoint(
        quote do
          signer AshHooks.HostExtensionDslTest.NoBehaviour
        end
      )
    end)

    assert_dsl_error(~r/signer must implement AshHooks.Signer/, fn ->
      endpoint(
        quote do
          signer String
        end
      )
    end)
  end

  test "Spark refuses absent, sensitive and unreadable signer attributes" do
    for {attribute, pattern} <- [
          {:absent, ~r/must name resource attributes/},
          {:credential, ~r/must not be sensitive/},
          {:opaque, ~r/JSON-readable stored type/},
          {:unreadable, ~r/JSON-readable stored type/}
        ] do
      assert_dsl_error(pattern, fn ->
        endpoint(
          quote do
            signer AshHooks.HostExtensionDslTest.ValidSigner
            signer_attributes [unquote(attribute)]
          end
        )
      end)
    end
  end

  test "optional native signing requires a signer and makes only secret_ref nullable" do
    assert_dsl_error(~r/optional requires signer/, fn ->
      endpoint(
        quote do
          native_signing :optional
        end
      )
    end)

    required =
      endpoint(
        quote do
        end
      )

    optional =
      endpoint(
        quote do
          signer AshHooks.HostExtensionDslTest.ValidSigner
          signer_attributes [:algorithm, :identifier, :labels]
          native_signing :optional
        end
      )

    refute ResourceInfo.attribute(required, :secret_ref).allow_nil?
    assert ResourceInfo.attribute(optional, :secret_ref).allow_nil?

    assert ResourceInfo.attribute(required, :url) ==
             ResourceInfo.attribute(optional, :url)

    overridden =
      resource(
        AshHooks.Endpoint,
        quote do
          attributes do
            attribute :secret_ref, :string, allow_nil?: false
          end

          endpoint do
            signer AshHooks.HostExtensionDslTest.ValidSigner
            native_signing :optional
          end
        end
      )

    assert ResourceInfo.attribute(overridden, :secret_ref).allow_nil?
  end

  test "new facts and provenance columns stay absent with defaults and facts is always reserved" do
    off =
      resource(
        AshHooks.InboundDelivery,
        quote do
        end
      )

    refute ResourceInfo.attribute(off, :verified_facts)

    on =
      resource(
        AshHooks.InboundDelivery,
        quote do
          inbound_delivery do
            record_verified_facts :on
          end
        end
      )

    assert %{sensitive?: true, allow_nil?: true} =
             ResourceInfo.attribute(on, :verified_facts)

    assert :verified_facts in ResourceInfo.action(on, :ingest).accept
    refute :verified_facts in ResourceInfo.action(off, :ingest).accept

    for mode <- [:on, :off] do
      assert_raise DslError, ~r/collides with an injected ledger field/, fn ->
        resource(
          AshHooks.InboundDelivery,
          quote do
            inbound_delivery do
              record_verified_facts unquote(mode)
              scope_identity [:verified_facts]
            end
          end
        )
      end
    end

    old_attempt =
      resource(
        AshHooks.OutboundAttempt,
        quote do
        end
      )

    refute ResourceInfo.attribute(old_attempt, :signing_key_refs)

    new_attempt =
      resource(
        AshHooks.OutboundAttempt,
        quote do
          outbound_attempt do
            record_signing_provenance :on
          end
        end
      )

    assert %{allow_nil?: true} = ResourceInfo.attribute(new_attempt, :signing_key_refs)
    assert :signing_key_refs in ResourceInfo.action(new_attempt, :record).accept
    refute :signing_key_refs in ResourceInfo.action(old_attempt, :record).accept
  end

  defp assert_dsl_error(pattern, fun) do
    errors = Dsl.errors(fun)

    assert [{_module, [%DslError{} = error]}] = errors
    assert Exception.message(error) =~ pattern
  end

  defp endpoint(options) do
    resource(
      AshHooks.Endpoint,
      quote do
        attributes do
          attribute :credential, :string, sensitive?: true
          attribute :opaque, :term
          attribute :algorithm, :atom
          attribute :identifier, :uuid
          attribute :labels, {:array, :string}
          attribute :unreadable, AshHooks.HostExtensionDslTest.UnreadableType
        end

        endpoint do
          unquote(options)
        end
      end
    )
  end

  defp resource(extension, options) do
    module = Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    Module.create(
      module,
      quote do
        use Ash.Resource,
          data_layer: Ash.DataLayer.Ets,
          validate_domain_inclusion?: false,
          extensions: [unquote(extension)]

        unquote(options)
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end
end
