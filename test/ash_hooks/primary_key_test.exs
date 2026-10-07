defmodule AshHooks.PrimaryKeyTest do
  use ExUnit.Case, async: true

  defmodule Composite do
    use Ash.Resource,
      domain: AshHooks.PrimaryKeyTest.Domain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      attribute :account_id, :string do
        primary_key?(true)
        allow_nil?(false)
        constraints(min_length: 2, max_length: 20)
      end

      attribute :sequence, :integer do
        primary_key?(true)
        allow_nil?(false)
        constraints(min: 1)
      end

      attribute(:id, :uuid, writable?: true)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end
  end

  defmodule Domain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(Composite)
    end
  end

  defmodule Single do
    use Ash.Resource,
      domain: AshHooks.PrimaryKeyTest.SingleDomain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:ledger_key)
      attribute(:id, :uuid, writable?: true)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule SingleDomain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(Single)
    end
  end

  alias AshHooks.PrimaryKey

  test "map and filter use every primary-key component and ignore writable non-key id" do
    record = %Composite{account_id: "acme", sequence: 7, id: Ash.UUID.generate()}

    assert PrimaryKey.map(record) == %{account_id: "acme", sequence: 7}
    assert PrimaryKey.filter(record) == %{account_id: "acme", sequence: 7}
  end

  test "encode emits a JSON-safe string-key map and decode restores typed keys" do
    record = %Composite{account_id: "acme", sequence: 7, id: Ash.UUID.generate()}

    assert %{"account_id" => "acme", "sequence" => 7} = encoded = PrimaryKey.encode(record)
    assert {:ok, decoded_json} = encoded |> Jason.encode!() |> Jason.decode()

    assert {:ok, %{account_id: "acme", sequence: 7}} =
             PrimaryKey.decode(Composite, decoded_json)
  end

  test "encode accepts a primary-key map without treating an id alias as identity" do
    assert PrimaryKey.encode(%{account_id: "acme", sequence: 7}) ==
             %{"account_id" => "acme", "sequence" => 7}
  end

  test "encode rejects non-stringable names and both JSON-unsafe value classes" do
    assert_raise ArgumentError, "primary-key names must be atoms or strings", fn ->
      PrimaryKey.encode(%{1 => "value"})
    end

    for unsafe <- [self(), <<255>>] do
      assert_raise ArgumentError, "primary key contains a value that is not JSON-safe", fn ->
        PrimaryKey.encode(%{account_id: unsafe, sequence: 7})
      end
    end
  end

  test "decode requires the exact declared key set and applies type constraints" do
    assert {:error, :primary_key_mismatch} =
             PrimaryKey.decode(Composite, %{"account_id" => "acme"})

    assert {:error, :primary_key_mismatch} =
             PrimaryKey.decode(Composite, %{
               "account_id" => "acme",
               "sequence" => 7,
               "id" => Ash.UUID.generate()
             })

    assert {:error, :invalid_primary_key} =
             PrimaryKey.decode(Composite, %{"account_id" => "a", "sequence" => 0})
  end

  test "decode does not create atoms from attacker-controlled keys" do
    unknown = "attacker_key_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, :primary_key_mismatch} =
             PrimaryKey.decode(Composite, %{
               "account_id" => "acme",
               "sequence" => 7,
               unknown => "value"
             })

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "decode rejects non-map input and map rejects incomplete records" do
    assert {:error, :primary_key_mismatch} = PrimaryKey.decode(Composite, "not-a-map")

    assert_raise ArgumentError, "record has an incomplete primary key", fn ->
      PrimaryKey.map(%Composite{account_id: "acme", sequence: nil})
    end
  end

  test "scalar! returns the sole real primary key and ignores a non-key id alias" do
    key = Ash.UUID.generate()
    record = %Single{ledger_key: key, id: Ash.UUID.generate()}
    assert PrimaryKey.scalar!(record) == key
  end

  test "scalar! rejects composite keys" do
    record = %Composite{account_id: "acme", sequence: 7, id: Ash.UUID.generate()}

    assert_raise ArgumentError, ~r/exactly one primary-key component/, fn ->
      PrimaryKey.scalar!(record)
    end
  end
end
