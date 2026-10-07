defmodule AshHooks.MixProject do
  use Mix.Project

  @version "2.0.3"
  @source_url "https://github.com/baselabs/ash_hooks"

  def project do
    [
      app: :ash_hooks,
      version: @version,
      # CONSUMER-FACING SUPPORT WINDOW: a floor, never a pin — a library
      # must not force every consumer onto one Elixir build. Floor is 1.20
      # (owner decision 2026-09-16: nothing below 1.20 is supported); CI's
      # floor leg proves the resolver stays coherent at it. The repo's
      # OWN development runs on one pinned toolchain (.tool-versions,
      # mirrored by a dedicated CI leg) and config/config.exs refuses any
      # OTP release CI does not test — that repo-local enforcement never
      # ships (config/ is excluded from the package). The window,
      # .tool-versions, the OTP allowlist, and the CI matrix move
      # together in ONE commit.
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      # The production consumer is executed separately. Its fetched dependencies
      # and build output are outside this application's ExUnit source surface.
      test_ignore_filters: [
        ~r{\Atest/consumer/(deps|_build)/},
        ~r{\Atest/consumer/(mix|verify)\.exs\z}
      ],
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      name: "AshHooks",
      description:
        "Webhooks for Ash Framework — inbound verification + dedup, outbound signing + delivery",
      source_url: @source_url,
      homepage_url: @source_url,
      # :ecto_sql is explicit because `use AshSqlite.Repo` (test/support)
      # macro-emits Ecto.Adapters.SQL delegations — the deps-PLT app
      # enumeration does not reliably include it, and without it dialyzer
      # reports those delegations as unknown functions. :ash_postgres
      # carries the PG repo's behaviour callbacks (callback_info_missing
      # on a fresh PLT, CI 2026-10-05).
      dialyzer: [plt_add_apps: [:mix, :ash_sqlite, :ash_postgres, :ecto_sql]],
      # Require 100% in Mix's declared coverage surface. ignore_modules
      # excludes entire modules, not individual lines: generated Spark
      # entities, named test fixtures, three Ash types, and the installer.
      # The types and installer have separate executed tests, but their
      # runtime lines do not contribute to this percentage. Their exclusions
      # avoid compile-window lines that run before :cover starts. Do not
      # expand this list to hide an uncovered runtime branch.
      test_coverage: [
        summary: [threshold: 100],
        ignore_modules: [
          ~r/^AshHooks\.Webhooks\.Inbound$/,
          ~r/^AshHooks\.Webhooks\.Outbound$/,
          ~r/AshHooks\.Webhooks\.(Inbound|Outbound)\.Options/,
          ~r/^AshHooks\.CountingProvider/,
          ~r/^AshHooks\.TestAstTripwire/,
          ~r/^AshHooks\.TestPerConnectionProvider/,
          ~r/^AshHooks\.TestPostgres\.Repo/,
          ~r/^AshHooks\.Endpoint\.Url/,
          ~r/^AshHooks\.Endpoint\.SecretRef/,
          ~r/^AshHooks\.InboundDelivery\.Payload/,
          ~r/Mix\.Tasks\.AshHooks\.Install/
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]]

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
      # 3.34.3 fixes CVE-2026-94201 and supplies the tenant inverse API
      # used by the worker. Older releases are not a supported consumer graph.
      {:ash, ">= 3.34.3 and < 4.0.0-0"},
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
        {:ash_sqlite, "~> 0.2.17", only: [:dev, :test], runtime: false},
        # The AshPostgres consumer leg (CI's postgres job): exercises the
        # transformers against a uuid_v7-keyed, sole-store-payload consumer
        # shape — the gaps sqlite alone could not surface. Dev/test-only;
        # the :postgres-tagged suite is excluded unless
        # ASH_HOOKS_POSTGRES=1 starts the repo.
        {:ash_postgres, "~> 2.0", only: [:dev, :test], runtime: false}
      ]
  end

  defp package do
    [
      maintainers: ["rjpalermo"],
      # The documentation tree ships because shipped docs (UPGRADING.md,
      # CHANGELOG) point adopters at repo-relative paths under it. Subtrees
      # are named individually — not `documentation` — so untracked files at
      # its root (.DS_Store) can never ride a glob into the tarball.
      files:
        ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* usage-rules* SECURITY* CONTRIBUTING* UPGRADING* documentation/tutorials documentation/livebooks documentation/dsls),
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
        [
          "README.md",
          "CHANGELOG.md",
          "usage-rules.md",
          "UPGRADING.md",
          "SECURITY.md",
          "CONTRIBUTING.md"
        ] ++
          Path.wildcard("documentation/tutorials/*.md") ++
          Path.wildcard("documentation/dsls/*.md") ++
          Path.wildcard("documentation/livebooks/*.livemd"),
      groups_for_extras: [
        Tutorials: ~r"documentation/tutorials/?",
        Livebooks: ~r"documentation/livebooks/?",
        DSLs: ~r"documentation/dsls/?"
      ],
      groups_for_modules: [
        Core: [
          AshHooks,
          AshHooks.Info,
          AshHooks.PrimaryKey,
          AshHooks.Ssrf,
          AshHooks.Telemetry,
          AshHooks.Tenancy
        ],
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
          AshHooks.OutboundBinding,
          AshHooks.Outbound,
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
