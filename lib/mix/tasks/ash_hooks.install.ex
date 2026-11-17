# Igniter is an optional dev/test dependency; the guard keeps the package
# compiling where it is absent.
if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.AshHooks.Install do
    @shortdoc "Installs ash_hooks: formatter import_deps + endpoint body_reader"

    @moduledoc """
    Installs ash_hooks into a host application:

    - adds `:ash_hooks` to `.formatter.exs` `import_deps` (DSL formatting);
    - configures an endpoint's `Plug.Parsers` without replacing its existing body reader.
      When absent, adds
      `body_reader: {AshHooks.BodyReader, :read_body, []}` so inbound
      verification sees the raw pre-parser bytes (a router plug cannot
      capture them). Existing custom readers must call `AshHooks.BodyReader.put_raw_body/2`
      with the complete body. The installer reports the manual step when it cannot
      safely configure the endpoint.

    ## Usage

    ```sh
    mix igniter.install ash_hooks
    ```
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Code.Function
    alias Igniter.Code.Keyword, as: IK
    alias Igniter.Project.Formatter
    alias Sourceror.Zipper

    @body_reader_value quote do: {AshHooks.BodyReader, :read_body, []}

    @manual_step "Configure Plug.Parsers with body_reader: {AshHooks.BodyReader, :read_body, []} " <>
                   "before parsers consume the request body. If using a custom reader, call " <>
                   "AshHooks.BodyReader.put_raw_body/2 with the complete body."

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      glob = GlobEx.compile!("lib/**/*endpoint.ex")

      igniter =
        igniter
        |> Formatter.import_dep(:ash_hooks)
        |> Igniter.include_glob(glob)

      paths = for source <- igniter.rewrite, GlobEx.match?(glob, source.path), do: source.path

      case paths do
        [] -> Igniter.add_notice(igniter, @manual_step)
        paths -> Enum.reduce(paths, igniter, &patch_endpoint/2)
      end
    end

    defp patch_endpoint(path, igniter) do
      source = Rewrite.source!(igniter.rewrite, path)
      zipper = source |> Rewrite.Source.get(:quoted) |> Zipper.zip()

      result =
        case move_to_parsers(zipper) do
          {:ok, parsers} -> add_body_reader(parsers)
          :error -> {:notice, @manual_step}
        end

      case result do
        {:ok, patched} ->
          Igniter.update_elixir_file(igniter, path, fn _ -> {:ok, patched} end)

        :unchanged ->
          igniter

        {:notice, notice} ->
          Igniter.add_notice(igniter, "#{path}: #{notice}")
      end
    end

    defp move_to_parsers(zipper) do
      Function.move_to_function_call(zipper, :plug, 2, fn call ->
        with %Zipper{} = first_arg <- Zipper.down(call),
             true <- module_matches?(first_arg, Plug.Parsers) do
          true
        else
          _ -> false
        end
      end)
    end

    defp module_matches?(first_arg, module) do
      marker = {:__ash_hooks_parsers_argument__, [], [Zipper.node(first_arg)]}

      # Expand grouped aliases into their equivalent declarations only in the
      # lookup tree. Igniter then resolves lexical aliases, including shadowing.
      normalized =
        first_arg
        |> Zipper.replace(marker)
        |> Zipper.topmost_root()
        |> Macro.prewalk(fn
          {:alias, meta, [{{:., _, [{:__aliases__, prefix_meta, prefix}, :{}]}, _, children}]} ->
            aliases =
              Enum.map(children, fn {:__aliases__, _, suffix} ->
                {:alias, meta, [{:__aliases__, prefix_meta, prefix ++ suffix}]}
              end)

            {:__block__, [], aliases}

          node ->
            node
        end)
        |> Zipper.zip()

      {:ok, argument} = Common.move_to(normalized, &match?(%Zipper{node: ^marker}, &1))
      Common.nodes_equal?(Zipper.down(argument), module)
    end

    defp add_body_reader(zipper) do
      opts = zipper |> Zipper.down() |> Zipper.right()

      if literal_keyword?(opts) do
        case IK.get_key(opts, :body_reader) do
          {:ok, reader} ->
            existing_reader(reader)

          :error ->
            {:ok, patched} = IK.set_keyword_key(opts, :body_reader, @body_reader_value)
            {:ok, Zipper.topmost(patched)}
        end
      else
        {:notice, @manual_step}
      end
    end

    defp literal_keyword?(opts) do
      opts
      |> Zipper.node()
      |> Macro.prewalk(fn
        {:__block__, _, [node]} -> node
        node -> node
      end)
      |> Keyword.keyword?()
    end

    defp existing_reader(reader) do
      with true <- Igniter.Code.Tuple.tuple?(reader),
           %Zipper{} = module <-
             reader |> Common.maybe_move_to_single_child_block() |> Zipper.down(),
           true <- module_matches?(module, AshHooks.BodyReader) do
        :unchanged
      else
        _ -> {:notice, @manual_step}
      end
    end
  end
else
  defmodule Mix.Tasks.AshHooks.Install do
    @shortdoc "Installs ash_hooks (requires the :igniter dep)"

    @moduledoc """
    Install task requires `:igniter` (a dev dependency). Add it, or follow the
    README's manual setup.
    """

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.raise("""
      mix ash_hooks.install requires the :igniter package.

      Add to mix.exs:

          {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}

      Then re-run. Manual steps are in the ash_hooks README.
      """)
    end
  end
end
