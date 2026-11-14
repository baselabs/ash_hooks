defmodule AshHooks.InboundSourceExtensionTest do
  use ExUnit.Case, async: false
  alias Ash.Resource.Info
  alias AshHooks.InboundSource.Transformers.AddSourceFields
  require Spark.Test

  defmodule ByteProvider do
    def webhook_signing_secret(_), do: {:ok, "declaration-key"}
  end

  test "injects identity, fields, actions and default acceptance before Ash consumers" do
    assert AddSourceFields.before?(Ash.Resource.Transformers.AttributesByName)

    source = compile_source()
    assert Info.identity(source, :unique_source).keys == [:source, :account_id]
    assert :provider in Info.action(source, :create).accept
    assert :account_id in Info.action(source, :create).accept
    assert Info.attribute(source, :provider).constraints[:one_of] == [:checked]
    refute Info.attribute(source, :source).allow_nil?
    refute Info.attribute(source, :account_id).allow_nil?

    for name <-
          ~w(secret_ref secret_kind previous_secret_ref previous_secret_kind public_key public_key_kind paused secret_created_at secret_first_used_at previous_secret_created_at previous_secret_first_used_at previous_secret_retired_at)a do
      assert Info.attribute(source, name)
    end

    for name <-
          ~w(roll_secret schedule_previous_retirement expire_previous_secret pause unpause register_public_key mark_current_secret_used mark_previous_secret_used read_custody_owner)a do
      assert Info.action(source, name)
    end

    for action <- Info.actions(source),
        argument <- Map.get(action, :arguments, []),
        argument.name in [:new_secret_ref, :old_ref, :public_key] do
      assert argument.sensitive?
    end
  end

  test "role names cannot duplicate or replace injected fields" do
    for options <- [
          [source_attribute: :provider],
          [source_attribute: :account_id],
          [scope: [{:paused, :boolean, []}]],
          [scope: [{:account_id, :string, []}, {:account_id, :string, []}]]
        ] do
      assert_raise Spark.Error.DslError, ~r/collid|distinct/, fn -> compile_source(options) end
    end
  end

  test "host attributes must match injected type, constraints and nullability" do
    for attribute <- [
          quote(do: attribute(:provider, :string, allow_nil?: false)),
          quote(do: attribute(:provider, :atom, allow_nil?: false)),
          quote(do: attribute(:provider, :atom, constraints: [one_of: [:checked]])),
          quote(do: attribute(:account_id, :string, allow_nil?: true))
        ] do
      assert_raise Spark.Error.DslError, ~r/match/, fn ->
        compile_source(attributes: attribute)
      end
    end

    source =
      compile_source(
        attributes:
          quote(
            do: attribute(:provider, :atom, allow_nil?: false, constraints: [one_of: [:checked]])
          )
      )

    assert Info.attribute(source, :provider).type == Ash.Type.Atom
  end

  test "duplicate machine action names are rejected" do
    assert_raise Spark.Error.DslError, ~r/Multiple actions.*pause/s, fn ->
      compile_source(actions: quote(do: update(:pause, accept: [])))
    end
  end

  test "source and ledger tenancy agree in strategy, attribute name and type" do
    for options <- [
          [source_tenancy: false],
          [tenant_name: :organization_id],
          [tenant_type: :string],
          [global?: true]
        ] do
      assert_source_error(options, ~r/tenancy/)
    end

    assert compile_source()

    errors =
      Spark.Test.dsl_errors do
        compile_source(source_tenancy: false, ledger_tenancy: false, registry_tenancy: false)
      end

    assert errors == []
  end

  test "source scope matches the ledger in name, type and constraints" do
    for scope <- [
          [],
          [{:other_id, :string, []}],
          [{:account_id, :integer, []}],
          [{:account_id, :string, [min_length: 2]}]
        ] do
      assert_source_error([scope: scope], ~r/scope/)
    end
  end

  test "source actions cannot bypass multitenancy" do
    assert_source_error(
      [actions: quote(do: read(:all_tenants, multitenancy: :bypass))],
      ~r/multitenant resource/
    )
  end

  test "overlap limits include the effective default" do
    assert_source_error([max_overlap_seconds: 60], ~r/default_overlap_seconds/)

    assert_source_error(
      [max_overlap_seconds: 60, default_overlap_seconds: 61],
      ~r/default_overlap_seconds/
    )

    assert compile_source(max_overlap_seconds: 60, default_overlap_seconds: 0)

    for value <- [-1, "60", 1.5] do
      assert_raise Spark.Error.DslError, fn -> compile_source(default_overlap_seconds: value) end
    end
  end

  test "custody tenant types require the same canonicalization coverage as endpoints" do
    assert_source_error(
      [tenant_type: :decimal, ledger_tenant_type: :decimal],
      ~r/custody_tenant_key/
    )

    assert compile_source(
             tenant_type: :decimal,
             ledger_tenant_type: :decimal,
             registry_tenant_type: :decimal,
             custody_tenant_key: {__MODULE__, :canonical_decimal, []}
           )
  end

  test "a registry with incompatible storage or tenancy is refused" do
    assert_source_error([registry_tenancy: false], ~r/registr/)
    assert_source_error([registry_repo: AshHooks.Test.RegistryOtherRepo], ~r/repo/)
    assert_source_error([registry_extension: false], ~r/registr/)
    assert_source_error([ledger_extension: false], ~r/ledger/)
  end

  test "provider allowlists are nonempty and have distinct aliases and module values" do
    for providers <- [
          [],
          [checked: nil],
          [checked: "provider"],
          [
            checked: AshHooks.Test.CustodySchemeProvider,
            checked: AshHooks.Test.CustodyHmacProvider
          ]
        ] do
      assert_source_error([providers: providers], ~r/providers/)
    end
  end

  test "source resources compile in custody-only mode" do
    previous = Application.fetch_env(:ash_hooks, :key_material)
    Application.put_env(:ash_hooks, :key_material, :custody_only)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_hooks, :key_material, value)
        :error -> Application.delete_env(:ash_hooks, :key_material)
      end
    end)

    assert compile_source()
    assert_source_error([providers: [checked: ByteProvider]], ~r/custody_only/)
  end

  def canonical_decimal(value), do: Decimal.to_string(Decimal.normalize(value))

  defp assert_source_error(opts, message) do
    errors = Spark.Test.dsl_errors(do: compile_source(opts))
    assert [{_, errors}] = errors
    assert Enum.any?(errors, &(Exception.message(&1) =~ message))
  end

  defp compile_source(opts \\ []) do
    root = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
    source = Module.concat(root, Source)
    ledger = Module.concat(root, Ledger)
    registry = Module.concat(root, Registry)

    on_exit(fn ->
      for module <- [source, ledger, registry] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    for {module, extension, tenancy?, name, type} <- [
          {registry, AshHooks.KeyRegistry, Keyword.get(opts, :registry_tenancy, true), :tenant_id,
           Keyword.get(opts, :registry_tenant_type, :integer)},
          {ledger, AshHooks.InboundDelivery, Keyword.get(opts, :ledger_tenancy, true), :tenant_id,
           Keyword.get(opts, :ledger_tenant_type, :integer)}
        ] do
      compile_peer(module, extension, tenancy?, name, type, ledger, registry, opts)
    end

    source_options =
      Keyword.take(opts, [
        :source_attribute,
        :scope,
        :max_overlap_seconds,
        :default_overlap_seconds,
        :custody_tenant_key
      ])
      |> Keyword.put_new(:scope, [{:account_id, :string, []}])
      |> Enum.map(fn {name, value} -> {name, [], [Macro.escape(value)]} end)

    name = Keyword.get(opts, :tenant_name, :tenant_id)

    compile(
      source,
      quote do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: AshSqlite.DataLayer,
          extensions: [AshHooks.InboundSource]

        sqlite do
          table("source_extension")
          repo(AshHooks.Test.RegistryRepo)
        end

        attributes do
          attribute(unquote(name), unquote(Keyword.get(opts, :tenant_type, :integer)),
            allow_nil?: false
          )

          unquote(opts[:attributes])
        end

        unquote(
          tenancy(
            Keyword.get(opts, :source_tenancy, true),
            name,
            Keyword.get(opts, :global?, false)
          )
        )

        actions do
          defaults([:read, :create, :update])
          default_accept(:*)
          unquote(opts[:actions])
        end

        inbound_source do
          ledger(unquote(ledger))
          key_registry(unquote(registry))
          custodian(AshHooks.Test.Custodian)

          providers(
            unquote(Keyword.get(opts, :providers, checked: AshHooks.Test.CustodySchemeProvider))
          )

          unquote_splicing(source_options)
        end
      end
    )

    source
  end

  defp compile_peer(module, extension, tenancy?, name, type, ledger, registry, opts) do
    extension_key = if module == ledger, do: :ledger_extension, else: :registry_extension
    extensions = if Keyword.get(opts, extension_key, true), do: [extension], else: []
    fallback_id = if extensions == [], do: quote(do: uuid_primary_key(:id))

    repo =
      if module == registry,
        do: Keyword.get(opts, :registry_repo, AshHooks.Test.RegistryRepo),
        else: AshHooks.Test.RegistryRepo

    definition =
      quote do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: AshSqlite.DataLayer,
          extensions: unquote(extensions)

        sqlite do
          table("source_extension")

          repo(unquote(repo))
        end

        attributes do
          unquote(fallback_id)

          attribute(unquote(name), unquote(type), allow_nil?: false)
          attribute(:account_id, :string, allow_nil?: false)
        end

        unquote(tenancy(tenancy?, name, false))

        unquote(
          if module == ledger and Keyword.get(opts, :ledger_extension, true) do
            quote do
              inbound_delivery do
                scope_identity([:account_id])
              end
            end
          end
        )

        actions do
          defaults([:read])
        end
      end

    compile(module, definition)
  end

  defp tenancy(false, _name, _global?), do: nil

  defp tenancy(true, name, global?) do
    quote do
      multitenancy do
        strategy(:attribute)
        attribute(unquote(name))
        global?(unquote(global?))
      end
    end
  end

  defp compile(module, body) do
    Code.compile_quoted(quote(do: defmodule(unquote(module), do: unquote(body))))
  end
end
