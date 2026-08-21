# Igniter is an optional dev/test dependency; the guard keeps the package
# compiling where it is absent (ADR-0004 — the ash-core pattern for optional
# deps, as in ash's own `ash.extend` task).
if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.AshHooks.Install do
    @shortdoc "Installs ash_hooks: formatter import_deps + endpoint body_reader"

    @moduledoc """
    Installs ash_hooks into a host application:

    - adds `:ash_hooks` to `.formatter.exs` `import_deps` (DSL formatting);
    - patches the endpoint's `Plug.Parsers` with
      `body_reader: {AshHooks.BodyReader, :read_body, []}` so inbound
      verification sees the raw pre-parser bytes (a router plug CANNOT
      capture them — see docs/adr).

    ## Usage

        mix igniter.install ash_hooks
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Function
    alias Igniter.Code.Keyword, as: IK
    alias Igniter.Project.Formatter
    alias Sourceror.Zipper

    @body_reader_value quote do: {AshHooks.BodyReader, :read_body, []}

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> Formatter.import_dep(:ash_hooks)
      |> Igniter.update_glob("lib/**/*endpoint.ex", &patch_endpoint/1)
    end

    defp patch_endpoint(zipper) do
      case move_to_parsers(zipper) do
        {:ok, zipper} ->
          add_body_reader(zipper)

        :error ->
          zipper
      end
    end

    defp move_to_parsers(zipper) do
      Function.move_to_function_call(zipper, :plug, 2, fn call ->
        with %Zipper{} = first_arg <- Zipper.down(call),
             true <- parsers_argument?(Zipper.node(first_arg)) do
          true
        else
          _ -> false
        end
      end)
    end

    # `plug Plug.Parsers` parses as an alias AST node; `plug :"Plug.Parsers"`
    # (unlikely but legal) as an atom.
    defp parsers_argument?({:__aliases__, _, [:Plug, :Parsers]}), do: true
    defp parsers_argument?(Plug.Parsers), do: true
    defp parsers_argument?(_), do: false

    defp add_body_reader(zipper) do
      with %Zipper{} = first_arg <- Zipper.down(zipper),
           %Zipper{} = opts <- Zipper.right(first_arg),
           {:ok, opts} <- IK.set_keyword_key(opts, :body_reader, @body_reader_value) do
        # topmost of the MODIFIED zipper — the edit lives on opts' path
        Zipper.topmost(opts)
      else
        _ ->
          # opts missing or not a keyword list — leave the endpoint alone;
          # the README documents the manual step.
          zipper
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
