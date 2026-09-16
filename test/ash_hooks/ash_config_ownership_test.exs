defmodule AshHooks.AshConfigOwnershipTest do
  @moduledoc false
  use ExUnit.Case, async: true

  # Consumer configuration ownership: `config :ash` belongs to the host
  # application, not the library. Ash's own RequireStringLengthCountConfig
  # transformer skips library resources for exactly this reason ("the
  # library has no say over the host application's configuration"), and
  # the Ash 3.33 `default_string_length_count` choice is security-relevant
  # (GHSA-cwjv-574p-59f6). A compile-time `Application.put_env(:ash, ...)`
  # anywhere in lib/ would silently override every consumer's explicit
  # app-level choice — this tripwire keeps that door closed.

  @mutated_source """
  defmodule Offender do
    def set_default do
      Application.put_env(:ash, :default_string_length_count, :codepoints)
    end
  end
  """

  test "lib/ never writes :ash application environment" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(fn path ->
        ast = path |> File.read!() |> Code.string_to_quoted!()

        case ash_env_writes(ast) do
          [] -> []
          writes -> [{path, writes}]
        end
      end)

    assert offenders == []
  end

  test "the detector trips on an Application.put_env(:ash, ...) call (its own red-proof)" do
    clean = Code.string_to_quoted!("""
    defmodule Clean do
      def set_own_env do
        Application.put_env(:ash_hooks, :adapter, :bounded)
      end
    end
    """)

    mutated = Code.string_to_quoted!(@mutated_source)

    assert ash_env_writes(clean) == []
    assert [{:put_env, :ash}] = ash_env_writes(mutated)
  end

  # Only the literal `Application.put_env(:ash, ...)` form — the one call
  # that would write the shared Ash application environment from library
  # code. Both spellings of the module name (the alias AST node the
  # source form parses to, and the bare atom) stay literal matches so no
  # aliasing hides the write.
  defp ash_env_writes(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Application]}, :put_env]}, _, [:ash | _]} = node, acc ->
          {node, [{:put_env, :ash} | acc]}

        {{:., _, [Application, :put_env]}, _, [:ash | _]} = node, acc ->
          {node, [{:put_env, :ash} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end
end
