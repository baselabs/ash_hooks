defmodule AshHooks.CoverageSurfaceTest do
  use ExUnit.Case, async: false

  alias AshHooks.Endpoint.{SecretRef, Url}
  alias AshHooks.InboundDelivery.Payload

  require Spark.Test

  test "public storage types cast, load and dump their complete supported shapes" do
    assert Url.storage_type([]) == :text
    assert SecretRef.storage_type([]) == :text
    assert Payload.storage_type([]) == :map

    for module <- [Url, SecretRef], operation <- [:cast_stored, :dump_to_native] do
      assert {:ok, nil} = apply(module, operation, [nil, []])
      assert {:ok, "stored"} = apply(module, operation, ["stored", []])
      assert {:error, _} = apply(module, operation, [42, []])
    end

    assert Url.cast_input(nil, []) == {:ok, nil}
    assert Url.cast_input("https://example.com/hook", []) == {:ok, "https://example.com/hook"}
    assert {:error, _} = Url.cast_input("http://127.0.0.1", [])
    assert {:error, _} = Url.cast_input(42, [])
    assert SecretRef.cast_input(nil, []) == {:ok, nil}
    assert SecretRef.cast_input("stored-reference", []) == {:ok, "stored-reference"}

    for input <- ["", "whsec_material", "whsk_material", "whpk_material", 42] do
      assert {:error, _} = SecretRef.cast_input(input, [])
    end

    for operation <- [:cast_input, :cast_stored, :dump_to_native], value <- [nil, %{}, []] do
      assert {:ok, ^value} = apply(Payload, operation, [value, []])
    end

    for operation <- [:cast_input, :cast_stored, :dump_to_native] do
      assert :error = apply(Payload, operation, [42, []])
    end

    assert Payload.cast_input("null", []) == {:ok, nil}
    assert Payload.cast_input("{}", []) == {:ok, %{}}
    assert Payload.cast_input("[]", []) == {:ok, []}
    assert Payload.cast_input("42", []) == :error
    assert Payload.cast_input("invalid JSON", []) == :error
    assert Payload.apply_constraints(nil, []) == {:ok, nil}
    assert Payload.apply_constraints(%{}, []) == {:ok, %{}}
  end

  test "a declaration without an option block reaches native DSL validation" do
    errors =
      Spark.Test.dsl_errors do
        Code.compile_string("""
        defmodule AshHooks.CoverageSurfaceTest.BareInbound do
          use Ash.Resource, data_layer: Ash.DataLayer.Ets, extensions: [AshHooks]
          webhooks do
            inbound :incoming
          end
        end
        """)
      end

    assert [{AshHooks.CoverageSurfaceTest.BareInbound, errors}] = errors
    assert Enum.any?(errors, &(Exception.message(&1) =~ "has no provider"))

    errors =
      Spark.Test.dsl_errors do
        Code.compile_string("""
        defmodule AshHooks.CoverageSurfaceTest.BareOutbound do
          use Ash.Resource, data_layer: Ash.DataLayer.Ets, extensions: [AshHooks]
          webhooks do
            outbound :outgoing
          end
        end
        """)
      end

    assert errors == []

    assert [%AshHooks.Outbound{name: :outgoing}] =
             AshHooks.Info.webhooks(AshHooks.CoverageSurfaceTest.BareOutbound)
  end

  test "test repositories declare the real adapter version floor" do
    for repo <- [AshHooks.Test.Repo, AshHooks.Test.BusyRepo] do
      assert Version.compare(repo.min_sqlite_version(), "3.54.1") == :eq
    end

    assert Version.compare(AshHooks.TestPostgres.Repo.min_pg_version(), "16.0.0") == :eq
  end

  test "the connection provider's callbacks all implement the public contract" do
    provider = AshHooks.TestPerConnectionProvider
    assert provider.webhook_secret_scope() == :per_connection
    assert provider.verify_signature("body", %{}, "secret") == :ok
    assert provider.parse_event_type(%{}) == {:ok, :checked}

    assert {:ok, %AshHooks.Event{type: :checked, payload: %{}}} =
             provider.handle_event(:checked, %{})
  end

  test "the counting provider contains malformed types and reports each outcome" do
    provider = AshHooks.CountingProvider
    on_exit(&provider.cleanup/0)
    provider.put_sink(self())

    for input <- [
          %{},
          %{"type" => nil},
          %{"type" => "a-type-that-is-not-an-atom"},
          %{"type" => "nil"}
        ] do
      assert {:error, _} = provider.parse_event_type(input)
    end

    assert provider.parse_event_type(%{"type" => :checked}) == {:ok, :checked}
    assert provider.parse_event_type(%{"type" => "checked"}) == {:ok, :checked}

    for outcome <- [:ok, {:error, :retry, :reason}, {:error, :reason}, fn -> :ok end] do
      provider.put_outcome(outcome)
      result = provider.handle_event(:checked, %{})

      assert match?({:ok, %AshHooks.Event{}}, result) or match?({:error, _}, result) or
               match?({:error, _, _}, result)

      assert_received {:handled, :checked, %{}}
    end

    provider.cleanup()
    assert {:ok, %AshHooks.Event{}} = provider.handle_event(:checked, %{})
    mac = :crypto.mac(:hmac, :sha256, "secret", "body") |> Base.encode16(case: :lower)
    assert provider.verify_signature("body", %{signature: mac}, "secret") == :ok
  end
end
