# Igniter is an optional dev/test dependency; the guard keeps the package
# compiling where it is absent.
if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.AshHooks.Install do
    @shortdoc "Installs ash_hooks: formatter import_deps + endpoint body_reader"

    @moduledoc """
    Installs ash_hooks into a host application:

    - adds `:ash_hooks` to `.formatter.exs` `import_deps` (DSL formatting);
    - in each `lib/**/*endpoint.ex`, configures every `plug Plug.Parsers` call, in any
      spelling that resolves to `Plug.Parsers`, without replacing an existing body
      reader. When the options are a literal keyword list without `:body_reader`, it
      adds `body_reader: {AshHooks.BodyReader, :read_body, []}` so inbound
      verification sees the raw pre-parser bytes (a router plug cannot capture
      them). An existing custom reader is kept and must call
      `AshHooks.BodyReader.put_raw_body/2` with the complete body; the installer
      emits a notice saying so. When it finds no `Plug.Parsers` call or cannot read
      the options as a literal keyword list, it changes nothing and reports the
      manual step.

    ## Usage

    ```sh
    mix igniter.install ash_hooks
    ```
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Code.Keyword, as: IK
    alias Igniter.Project.Formatter
    alias Sourceror.Zipper

    @body_reader_value quote do: {AshHooks.BodyReader, :read_body, []}

    @manual_step "Configure Plug.Parsers with body_reader: {AshHooks.BodyReader, :read_body, []} before parsers consume the request body."

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter =
        igniter
        |> Formatter.import_dep(:ash_hooks)
        |> Igniter.include_glob("lib/**/*endpoint.ex")

      glob = GlobEx.compile!(Path.expand("lib/**/*endpoint.ex"))

      paths =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.map(& &1.path)
        |> Enum.filter(&GlobEx.match?(glob, Path.expand(&1)))

      if paths == [] do
        Igniter.add_notice(igniter, "No endpoint with Plug.Parsers was found. " <> @manual_step)
      else
        Enum.reduce(paths, igniter, &patch_endpoint/2)
      end
    end

    defp patch_endpoint(path, igniter) do
      quoted = igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:quoted)
      original = Zipper.zip(quoted)

      {updated, {found?, notices}} =
        Zipper.traverse(original, {false, []}, &patch_parser_node/2)

      igniter =
        if Zipper.node(updated) != quoted do
          Igniter.update_elixir_file(igniter, path, fn _ -> {:ok, updated} end)
        else
          igniter
        end

      notices = if found?, do: notices, else: ["No Plug.Parsers call was found. " <> @manual_step]

      Enum.reduce(notices, igniter, fn notice, acc ->
        Igniter.add_notice(acc, path <> ": " <> notice)
      end)
    end

    defp patch_parser_node(zipper, {found?, notices}) do
      case Zipper.node(zipper) do
        {:plug, _, [_ | _] = args} when length(args) in [1, 2] ->
          if module_matches?(Zipper.down(zipper), Plug.Parsers) do
            {zipper, notice} = patch_parsers(zipper)
            {zipper, {true, if(notice, do: [notice | notices], else: notices)}}
          else
            {zipper, {found?, notices}}
          end

        _ ->
          {zipper, {found?, notices}}
      end
    end

    defp patch_parsers(zipper) do
      with %Zipper{} = opts <- zipper |> Zipper.down() |> Zipper.right(),
           true <- literal_keyword?(opts) do
        case IK.get_key(opts, :body_reader) do
          {:ok, reader} ->
            {zipper, reader_notice(reader)}

          :error ->
            {:ok, updated} = IK.set_keyword_key(opts, :body_reader, @body_reader_value)
            {Zipper.up(updated), nil}
        end
      else
        _ -> {zipper, "Plug.Parsers options are not a literal keyword list. " <> @manual_step}
      end
    end

    defp reader_notice(reader) do
      if ash_hooks_reader?(reader) do
        nil
      else
        "The existing body_reader must call AshHooks.BodyReader.put_raw_body/2 with the complete body."
      end
    end

    defp literal_keyword?(zipper) do
      case zipper |> Common.maybe_move_to_single_child_block() |> Zipper.node() do
        list when is_list(list) -> Enum.all?(list, &keyword_pair?/1)
        _ -> false
      end
    end

    defp keyword_pair?({{:__block__, _, [key]}, _}) when is_atom(key), do: true
    defp keyword_pair?(_), do: false

    # A body reader is a literal `{module, function, args}` tuple; any other
    # expression is the host's own reader.
    defp ash_hooks_reader?(reader) do
      reader = Common.maybe_move_to_single_child_block(reader)

      case Zipper.node(reader) do
        {:{}, _, [_module, _function, _args]} ->
          reader |> Zipper.down() |> module_matches?(AshHooks.BodyReader)

        _ ->
          false
      end
    end

    defp module_matches?(zipper, module) do
      Macro.expand(quoted_node(zipper), lexical_env(zipper)) == module
    end

    defp quoted_node(zipper) do
      Macro.prewalk(Zipper.node(zipper), fn
        {:__block__, _, [value]} -> value
        node -> node
      end)
    end

    defp lexical_env(nil), do: Code.env_for_eval([])

    defp lexical_env(zipper) do
      lexical_env(Zipper.up(zipper), Zipper.left(zipper))
    end

    defp lexical_env(%Zipper{node: {:defmodule, _, [name, _]}} = parent, previous)
         when not is_nil(previous) do
      env = lexical_env(parent)
      %{env | module: declared_module(name, env)}
    end

    defp lexical_env(parent, nil), do: lexical_env(parent)

    defp lexical_env(_parent, previous),
      do: add_alias(quoted_node(previous), lexical_env(previous))

    defp declared_module({:__aliases__, _, [:"Elixir" | parts]}, _env), do: Module.concat(parts)

    defp declared_module({:__aliases__, _, [first | _] = parts} = name, env)
         when is_atom(first) do
      if env.module && !Keyword.has_key?(env.aliases, Module.concat([first])) do
        Module.concat([env.module | parts])
      else
        Macro.expand(name, env)
      end
    end

    defp declared_module(name, env), do: Macro.expand(name, env)

    defp add_alias({:alias, meta, [{{:., _, [base, :{}]}, _, members} | _options]}, env) do
      base = Macro.expand(base, env)

      Enum.reduce(members, env, fn {:__aliases__, _, parts}, acc ->
        define_alias(acc, meta, Module.concat([base | parts]), [])
      end)
    end

    defp add_alias({:alias, meta, [module | options]}, env) do
      options = List.first(options) || []
      options = Keyword.take(options, [:as])

      options =
        Enum.map(options, fn {:as, {:__aliases__, _, parts}} -> {:as, Module.concat(parts)} end)

      define_alias(env, meta, Macro.expand(module, env), options)
    end

    defp add_alias(_node, env), do: env

    defp define_alias(env, meta, module, options) do
      {:ok, env} = Macro.Env.define_alias(env, meta, module, [trace: false] ++ options)
      env
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
