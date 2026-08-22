defmodule AshHooks.MixProject do
  use Mix.Project

  @version "1.0.1"
  @source_url "https://github.com/baselabs/ash_hooks"

  def project do
    [
      app: :ash_hooks,
      version: @version,
      elixir: "~> 1.17",
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
      homepage_url: @source_url,
      dialyzer: [plt_add_apps: [:mix, :ash_sqlite]]
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
      {:telemetry, "~> 1.3"}
      | optional_deps
    ] ++
      [
        # Dev/Test
        {:igniter, "~> 0.6", only: [:dev, :test], runtime: false, optional: true},
        {:ex_doc, "~> 0.31", only: :dev, runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
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
      files:
        ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* usage-rules* SECURITY* CONTRIBUTING* UPGRADING*),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras:
        ["README.md", "CHANGELOG.md", "usage-rules.md", "UPGRADING.md", "SECURITY.md"] ++
          Path.wildcard("documentation/tutorials/*.md") ++
          Path.wildcard("documentation/dsls/*.md") ++
          Path.wildcard("documentation/livebooks/*.livemd"),
      groups_for_extras: [
        Tutorials: ~r"documentation/tutorials/?",
        Livebooks: ~r"documentation/livebooks/?",
        DSLs: ~r"documentation/dsls/?"
      ],
      groups_for_modules: [
        Core: [AshHooks, AshHooks.Info, AshHooks.Ssrf, AshHooks.Telemetry],
        Inbound: [
          AshHooks.BodyReader,
          AshHooks.Ingress,
          AshHooks.InboundDelivery,
          AshHooks.InboundDelivery.Payload
        ],
        Outbound: [
          AshHooks.Event,
          AshHooks.Subscription,
          AshHooks.Endpoint,
          AshHooks.OutboundDelivery,
          AshHooks.Dispatcher,
          AshHooks.Delivery,
          AshHooks.Worker
        ],
        Signing: [AshHooks.Signing, AshHooks.Legacy],
        Providers: [
          AshHooks.Provider,
          AshHooks.Provider.Mock,
          AshHooks.Provider.ComplyCube,
          AshHooks.Provider.HubSpotV3
        ],
        "HTTP adapters": [
          AshHooks.Http,
          AshHooks.Http.Bounded,
          AshHooks.Http.Httpc,
          AshHooks.Http.CertSan
        ]
      ]
    ]
  end

  defp aliases do
    [
      credo: ["credo --strict"]
    ]
  end
end
