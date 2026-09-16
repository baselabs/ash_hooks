defmodule AshHooks.AshConfigOwnershipTest do
  @moduledoc false
  use ExUnit.Case, async: true

  # Consumer configuration ownership: `config :ash` belongs to the host
  # application, not the library. Ash's own RequireStringLengthCountConfig
  # transformer skips library resources for exactly this reason ("the
  # library has no say over the host application's configuration"), and
  # the Ash 3.33 `default_string_length_count` choice is security-relevant
  # (GHSA-cwjv-574p-59f6). A compile-time write to the :ash application
  # environment anywhere in lib/ would silently override every consumer's
  # explicit app-level choice — this tripwire keeps that door closed.

  @mutated_source """
  defmodule Offender do
    alias Application, as: App

    def aliased_form do
      App.put_env(:ash, :default_string_length_count, :codepoints)
    end

    def erlang_form do
      :application.set_env(:ash, :default_string_length_count, :codepoints, persistent: true)
    end

    def bulk_form do
      Application.put_all_env(ash: [default_string_length_count: :codepoints])
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

  test "the detector trips on every :ash write form (its own red-proof)" do
    clean =
      Code.string_to_quoted!("""
      defmodule Clean do
        def set_own_env do
          Application.put_env(:ash_hooks, :adapter, :bounded)
          Application.put_all_env(ash_hooks: [adapter: :bounded])
        end
      end
      """)

    mutated = Code.string_to_quoted!(@mutated_source)

    assert ash_env_writes(clean) == []
    assert [put_env: :ash, set_env: :ash, put_all_env: :ash] = ash_env_writes(mutated)
  end

  # Any remote put_env/set_env whose FIRST argument is the literal :ash —
  # matching ANY module prefix, not only Application, so alias renames and
  # the Erlang :application.set_env/3 spelling cannot slip past (over-broad
  # is the fail-closed direction for a tripwire). Bulk form:
  # put_all_env with an :ash key in its keyword list.
  defp ash_env_writes(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_, fun]}, _, [:ash | _]} = node, acc when fun in [:put_env, :set_env] ->
          {node, [{fun, :ash} | acc]}

        {{:., _, [_, :put_all_env]}, _, [entries | _]} = node, acc ->
          if keyword_has_ash_key?(entries),
            do: {node, [{:put_all_env, :ash} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Keyword entries parse as 2-tuples ({:ash, value}); constructed forms
  # carry metadata as 3-tuples ({:ash, meta, value}) — match both.
  defp keyword_has_ash_key?([{:ash, _} | _]), do: true
  defp keyword_has_ash_key?([{:ash, _, _} | _]), do: true
  defp keyword_has_ash_key?([_ | rest]), do: keyword_has_ash_key?(rest)
  defp keyword_has_ash_key?(_), do: false
end
