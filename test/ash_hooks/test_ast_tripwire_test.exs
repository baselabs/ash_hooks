defmodule AshHooks.TestAstTripwireTest do
  use ExUnit.Case, async: true

  import AshHooks.TestAstTripwire

  @source """
  defmodule Sample do
    def verify(payload, signature) do
      expected = :crypto.mac(:hmac, :sha256, "k", payload)

      if byte_size(expected) == byte_size(signature) and
           :crypto.hash_equals(expected, signature) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end
  """

  @mutated_source """
  defmodule Sample do
    def verify(payload, signature) do
      expected = :crypto.mac(:hmac, :sha256, "k", payload)

      if byte_size(expected) == byte_size(signature) and expected == signature do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end
  """

  test "the bare-equality detector trips on a direct == on material names (its own red-proof)" do
    {:ok, clean} = Code.string_to_quoted(@source)
    {:ok, mutated} = Code.string_to_quoted(@mutated_source)

    refute module_compares_material_with_bare_equality?(clean, [:signature, :expected])
    assert module_compares_material_with_bare_equality?(mutated, [:signature, :expected])
  end

  test "guards wrapping the material (byte_size) do not trip the bare-equality detector" do
    refute module_compares_material_with_bare_equality?(source_ast_of_clean(), [:signature])
  end

  test "function detectors inspect guarded clauses and distinguish bare operands from wrappers" do
    ast = Code.string_to_quoted!("""
    defmodule Clauses do
      def verify(a, b) when is_binary(a), do: :crypto.hash_equals(a, b)
      def verify(a, b), do: byte_size(a) == byte_size(b)
      def other(a, b), do: a != b
    end
    """)

    [constant_time, wrapped] = function_bodies(ast, :verify)
    assert calls_constant_time_compare?(constant_time)
    refute calls_constant_time_compare?(wrapped)
    refute compares_with_bare_equality?(constant_time, [:a, :b])
    refute compares_with_bare_equality?(wrapped, [:a, :b])
    assert function_bodies(ast, :missing) == []

    for operator <- ["==", "!=", "===", "!=="], operands <- ["a #{operator} b", "1 #{operator} b"] do
      mutated = Code.string_to_quoted!(operands)
      assert compares_with_bare_equality?(mutated, [:a, :b])
      assert module_compares_material_with_bare_equality?(mutated, [:a, :b])
    end
  end

  defp source_ast_of_clean do
    {:ok, ast} = Code.string_to_quoted(@source)
    ast
  end
end
