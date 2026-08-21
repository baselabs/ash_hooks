defmodule AshHooks.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/baselabs/ash_hooks"

  def project do
    [
      app: :ash_hooks,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      name: "AshHooks",
      description:
        "Webhooks for Ash Framework — inbound verification + dedup, outbound signing + delivery",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    # Optional at runtime for CONSUMERS (hex metadata) — but listing them here
    # opts THIS dev build into compiling them (Mix builds a root project's own
    # optional deps). ASH_HOOKS_NO_OPTIONAL=1 drops them from the dep list
    # entirely: the CI no-optional leg uses it to prove the package compiles
    # and tests Oban/plug-free (ADR-0004).
    optional_deps =
      if System.get_env("ASH_HOOKS_NO_OPTIONAL") == "1" do
        []
      else
        [
          {:oban, "~> 2.20", optional: true},
          {:plug, "~> 1.16", optional: true}
        ]
      end

    [
      # Runtime
      {:ash, "~> 3.0"},
      {:splode, "~> 0.3"},
      {:spark, ">= 2.3.3 and < 3.0.0-0"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"}
      | optional_deps
    ] ++
      [
        # Dev/Test
        {:igniter, "~> 0.6", only: [:dev, :test], runtime: false, optional: true},
        {:ex_doc, "~> 0.31", only: :dev, runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:simple_sat, "~> 0.1", only: [:dev, :test], runtime: false},
        # Test substrate for the fenced-ledger concurrency tests (ADR-0003
        # names sqlite as the best-effort matrix leg). Dev/test-only: never
        # ships in hex metadata, never constrains consumers. ETS was probed
        # and cannot express storage-level uniqueness or conditional-update
        # atomicity (read-then-write on both paths).
        {:ash_sqlite, "~> 0.2.17", only: [:dev, :test], runtime: false}
      ]
  end

  defp package do
    [
      maintainers: ["rjpalermo"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp aliases do
    [
      credo: ["credo --strict"]
    ]
  end
end
