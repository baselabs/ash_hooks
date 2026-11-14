defmodule AshHooks.EndpointOverlapVerifierTest do
  use ExUnit.Case, async: false

  alias Ash.Resource.Info, as: ResourceInfo

  require Spark.Test

  test "a maximum below the built-in effective default is rejected" do
    module = fixture_module()

    errors =
      Spark.Test.dsl_errors do
        compile_endpoint(module, max_overlap_seconds: 86_399)
      end

    assert [{^module, [%Spark.Error.DslError{} = error]}] = errors
    assert error.path == [:endpoint, :max_overlap_seconds]
    assert Exception.message(error) =~ "default_overlap_seconds (86400)"
  end

  test "a configured default above the maximum is rejected" do
    module = fixture_module()

    errors =
      Spark.Test.dsl_errors do
        compile_endpoint(module, max_overlap_seconds: 60, default_overlap_seconds: 61)
      end

    assert [{^module, [%Spark.Error.DslError{} = error]}] = errors
    assert error.path == [:endpoint, :max_overlap_seconds]
    assert Exception.message(error) =~ "default_overlap_seconds (61)"
  end

  test "the maximum must be a positive integer" do
    for max <- [0, -1, 1.5, "60"] do
      assert_raise Spark.Error.DslError, ~r/max_overlap_seconds/, fn ->
        compile_endpoint(fixture_module(), max_overlap_seconds: max)
      end
    end
  end

  test "the configured default must be a non-negative integer" do
    for default <- [-1, 1.5, "60"] do
      assert_raise Spark.Error.DslError, ~r/default_overlap_seconds/, fn ->
        compile_endpoint(fixture_module(), default_overlap_seconds: default)
      end
    end
  end

  test "unset limits, equality, a zero default, and an uncapped default compile" do
    for opts <- [
          [],
          [max_overlap_seconds: 86_400],
          [max_overlap_seconds: 60, default_overlap_seconds: 60],
          [max_overlap_seconds: 1, default_overlap_seconds: 0],
          [default_overlap_seconds: 120]
        ] do
      errors =
        Spark.Test.dsl_errors do
          compile_endpoint(fixture_module(), opts)
        end

      assert errors == []
    end
  end

  test "legacy lifecycle requires the standard lifecycle" do
    module = fixture_module()

    errors =
      Spark.Test.dsl_errors do
        compile_endpoint(module, key_lifecycle: :off, legacy_key_lifecycle: :on)
      end

    assert [{^module, [%Spark.Error.DslError{} = error]}] = errors
    assert error.path == [:endpoint, :legacy_key_lifecycle]
    assert Exception.message(error) =~ "requires key_lifecycle :on"
  end

  test "legacy lifecycle off injects no legacy timestamps or actions" do
    for opts <- [[], [legacy_key_lifecycle: :off]] do
      module = fixture_module()
      compile_endpoint(module, opts)

      for field <- legacy_fields() do
        assert is_nil(ResourceInfo.attribute(module, field))
      end

      for action <- [:mark_legacy_current_secret_used, :mark_legacy_previous_secret_used] do
        assert is_nil(ResourceInfo.action(module, action))
      end
    end
  end

  test "legacy lifecycle on injects five nullable timestamps and first-use actions" do
    module = fixture_module()
    compile_endpoint(module, legacy_key_lifecycle: :on)

    standard_roll = ResourceInfo.action(module, :roll_secret)
    legacy_roll = ResourceInfo.action(module, :roll_legacy_secret)
    refute Enum.find(standard_roll.arguments, &(&1.name == :old_ref)).allow_nil?
    assert Enum.find(legacy_roll.arguments, &(&1.name == :old_ref)).allow_nil?

    for field <- legacy_fields() do
      attribute = ResourceInfo.attribute(module, field)
      assert attribute.type == Ash.Type.UtcDatetimeUsec
      assert attribute.allow_nil?
    end

    for action <- [:mark_legacy_current_secret_used, :mark_legacy_previous_secret_used] do
      assert ResourceInfo.action(module, action).type == :update
    end
  end

  defp legacy_fields do
    [
      :legacy_secret_created_at,
      :legacy_secret_first_used_at,
      :legacy_previous_secret_created_at,
      :legacy_previous_secret_first_used_at,
      :legacy_previous_secret_retired_at
    ]
  end

  defp fixture_module do
    module = Module.concat(__MODULE__, "Endpoint#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    module
  end

  defp compile_endpoint(module, opts) do
    {lifecycle, opts} = Keyword.pop(opts, :key_lifecycle, :on)
    options = Enum.map(opts, fn {name, value} -> {name, [], [value]} end)

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshSqlite.DataLayer,
            extensions: [AshHooks.Endpoint]

          sqlite do
            table("endpoint_overlap_verifier")
            repo(AshHooks.Test.Repo)
          end

          endpoint do
            key_lifecycle(unquote(lifecycle))
            unquote_splicing(options)
          end

          actions do
            defaults([:read])
          end
        end
      end
    )
  end
end
