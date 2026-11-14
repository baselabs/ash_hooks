defmodule AshHooks.CustodyTenantTest do
  use ExUnit.Case, async: true

  alias AshHooks.Custody

  defmodule Parser do
    def parse("account:" <> value, :integer), do: String.to_integer(value)
    def decimal_key(value, prefix), do: prefix <> Decimal.to_string(Decimal.normalize(value))
    def invalid_key(_value), do: 123
  end

  defmodule CustomTenantType do
    use Ash.Type.NewType, subtype_of: :string
  end

  for {name, type, constraints} <- [
        {__MODULE__.UuidOwner, :uuid, []},
        {__MODULE__.UuidV7Owner, :uuid_v7, [strict?: true]},
        {__MODULE__.IntegerOwner, :integer, []},
        {__MODULE__.StringOwner, :string, [trim?: false]},
        {__MODULE__.CiStringOwner, :ci_string, []},
        {__MODULE__.DecimalOwner, :decimal, []},
        {__MODULE__.CustomOwner, CustomTenantType, []}
      ] do
    defmodule name do
      use Ash.Resource, domain: nil, data_layer: AshSqlite.DataLayer

      sqlite do
        table("custody_tenant_owners")
        repo(AshHooks.Test.Repo)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:tenant_id, type, constraints: constraints, allow_nil?: false)
      end

      multitenancy do
        strategy(:attribute)
        attribute(:tenant_id)
      end
    end
  end

  alias __MODULE__.{
    CiStringOwner,
    CustomOwner,
    DecimalOwner,
    IntegerOwner,
    StringOwner,
    UuidOwner,
    UuidV7Owner
  }

  defmodule ParsedOwner do
    use Ash.Resource, domain: nil, data_layer: AshSqlite.DataLayer

    sqlite do
      table("custody_parsed_owners")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:tenant_id, :integer, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
      parse_attribute({Parser, :parse, [:integer]})
    end
  end

  defmodule PlainOwner do
    use Ash.Resource, domain: nil, data_layer: AshSqlite.DataLayer

    sqlite do
      table("custody_plain_owners")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end
  end

  defmodule ContextOwner do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Simple

    attributes do
      uuid_primary_key(:id)
    end

    multitenancy do
      strategy(:context)
    end
  end

  defmodule Tenant do
    defstruct [:value]
  end

  defimpl Ash.ToTenant, for: Tenant do
    def to_tenant(%{value: value}, _resource), do: "account:" <> value
  end

  @uuid_supported Custody.tenant_type_supported?(UuidOwner)
  @custom_supported Custody.tenant_type_supported?(CustomOwner)
  @decimal_hook_supported Custody.tenant_type_supported?(DecimalOwner,
                            custody_tenant_key: {Parser, :decimal_key, ["decimal:"]}
                          )

  test "equal UUID, UUIDv7, integer and ci_string spellings have one custody tenant" do
    uuid = "019a7612-abcd-7def-8123-0123456789ab"

    for owner <- [UuidOwner, UuidV7Owner] do
      assert {:ok, ^uuid} = Custody.canonical_tenant(uuid, owner)
      assert {:ok, ^uuid} = Custody.canonical_tenant(String.upcase(uuid), owner)
    end

    assert {:ok, "42"} = Custody.canonical_tenant(42, IntegerOwner)
    assert {:ok, "42"} = Custody.canonical_tenant("+0042", IntegerOwner)
    assert {:ok, "-42"} = Custody.canonical_tenant("-0042", IntegerOwner)
    assert {:ok, "mixed"} = Custody.canonical_tenant("MiXeD", CiStringOwner)
    assert {:ok, "mixed"} = Custody.canonical_tenant("mixed", CiStringOwner)
  end

  test "strings are exact valid UTF-8 and invalid tenant inputs are refused" do
    assert {:ok, " A "} = Custody.canonical_tenant(" A ", StringOwner)
    assert {:ok, "a"} = Custody.canonical_tenant("a", StringOwner)
    assert {:error, :invalid_tenant} = Custody.canonical_tenant(<<255>>, StringOwner)
    assert {:error, :invalid_tenant} = Custody.canonical_tenant("invalid", IntegerOwner)
    assert {:error, :invalid_tenant} = Custody.canonical_tenant(nil, IntegerOwner)
    assert {:ok, nil} = Custody.canonical_tenant(%{}, PlainOwner)
  end

  test "coverage is inspectable by a compile-time verifier and custom hooks receive cast values" do
    assert @uuid_supported
    refute @custom_supported
    assert @decimal_hook_supported

    for owner <- [UuidOwner, UuidV7Owner, IntegerOwner, StringOwner, CiStringOwner, PlainOwner] do
      assert Custody.tenant_type_supported?(owner)
    end

    refute Custody.tenant_type_supported?(DecimalOwner)
    refute Custody.tenant_type_supported?(CustomOwner)
    assert {:error, :unsupported_tenant_type} = Custody.canonical_tenant("1.0", DecimalOwner)
    opts = [custody_tenant_key: {Parser, :decimal_key, ["decimal:"]}]
    assert Custody.tenant_type_supported?(DecimalOwner, opts)
    assert {:ok, "decimal:1"} = Custody.canonical_tenant("1.0", DecimalOwner, opts)
    assert {:ok, "decimal:1"} = Custody.canonical_tenant("1.00", DecimalOwner, opts)

    assert {:error, :invalid_tenant} =
             Custody.canonical_tenant("1", DecimalOwner,
               custody_tenant_key: {Parser, :invalid_key, []}
             )
  end

  test "canonicalization follows ToTenant, parse_attribute, and cast_input with constraints" do
    assert {:ok, "42"} = Custody.canonical_tenant(%Tenant{value: "0042"}, ParsedOwner)
    assert {:ok, "42"} = Custody.canonical_tenant("account:0042", ParsedOwner)
  end

  test "context multitenancy has no canonical custody tenant" do
    refute Custody.tenant_type_supported?(ContextOwner)
    assert {:error, :unsupported_tenant_type} = Custody.canonical_tenant("org", ContextOwner)
  end
end
