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

  defp source_ast_of_clean do
    {:ok, ast} = Code.string_to_quoted(@source)
    ast
  end
end
