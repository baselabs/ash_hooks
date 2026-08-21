# Igniter is an optional dev/test dependency; the guard keeps the package
# compiling where it is absent (ADR-0004 — the ash-core pattern for optional
# deps, as in ash's own `ash.extend` task).
if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.AshHooks.Install do
    @shortdoc "Installs ash_hooks: adds :ash_hooks to formatter import_deps"

    @moduledoc """
    Installs ash_hooks into a host application: adds `:ash_hooks` to
    `.formatter.exs` `import_deps` so the DSL formats correctly.

    The inbound endpoint `body_reader` setup ships with the ingress slice —
    a router plug cannot capture pre-parser bytes (see docs/adr).

    ## Usage

        mix igniter.install ash_hooks
    """

    use Igniter.Mix.Task

    alias Igniter.Project.Formatter

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Formatter.import_dep(igniter, :ash_hooks)
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
