defmodule AshHooks.TestAstTripwire do
  @moduledoc false

  # Shared mutation-red tripwire helpers: assert a function in a source file
  # compares via :crypto.hash_equals/2 (never a bare equality operator on the
  # caller-named parameters), and prove the detector reds under the exact
  # named mutation (:crypto.hash_equals -> ==) applied in memory.

  def source_ast(path) do
    {:ok, ast} = path |> Path.expand() |> File.read!() |> Code.string_to_quoted()
    ast
  end

  # All clause bodies of `fun_name` in the module source — multi-clause
  # functions must hold the property in EVERY clause.
  def function_bodies(ast, fun_name) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head, block]} = node, acc ->
          if function_name(head) == fun_name do
            {node, [Keyword.fetch!(block, :do) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  def calls_constant_time_compare?(body) do
    Macro.prewalk(body, false, fn
      {:., _, [:crypto, :hash_equals]} = node, _acc -> {node, true}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  # `bare_params` — the parameter names (atoms) that must never appear as a
  # DIRECT operand of ==/!=/===/!== (guards wrapping them in byte_size/1 etc.
  # are fine — only bare comparisons trip it).
  def compares_with_bare_equality?(body, bare_params) do
    bare = MapSet.new(bare_params)

    Macro.prewalk(body, false, fn
      {op, _, [lhs, rhs]} = node, acc when op in [:==, :!=, :===, :!==] ->
        if bare_var?(lhs, bare) or bare_var?(rhs, bare) do
          {node, true}
        else
          {node, acc}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  def mutate_hash_equals_to_equals(ast) do
    Macro.prewalk(ast, fn
      {{:., meta, [:crypto, :hash_equals]}, _call_meta, args} -> {:==, meta, args}
      node -> node
    end)
  end

  # Module-level form: the constant-time compare may live in a private helper
  # the verifier delegates to, so the property is "the module calls
  # :crypto.hash_equals/2 somewhere" AND "no function anywhere in the module
  # compares the signature-material names with a bare equality operator".
  def module_calls_constant_time_compare?(ast) do
    Macro.prewalk(ast, false, fn
      {:., _, [:crypto, :hash_equals]} = node, _acc -> {node, true}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  def module_compares_material_with_bare_equality?(ast, material_names) do
    bare = MapSet.new(material_names)

    Macro.prewalk(ast, false, fn
      {op, _, [lhs, rhs]} = node, acc when op in [:==, :!=, :===, :!==] ->
        if bare_var?(lhs, bare) or bare_var?(rhs, bare) do
          {node, true}
        else
          {node, acc}
        end

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # A def with a `when` guard nests the call inside {:when, _, [call, guard]}.
  defp function_name({:when, _, [{name, _, _} | _]}), do: name
  defp function_name({name, _, _}), do: name

  defp bare_var?({name, _, _}, bare) when is_atom(name), do: MapSet.member?(bare, name)
  defp bare_var?(_, _), do: false
end
