defmodule AshHooks.MixProject do
  use Mix.Project

  @version "3.2.0"
  @source_url "https://github.com/baselabs/ash_hooks"
  # Every Spark extension the package ships. The formatter export and the DSL
  # references are generated from this one list.
  @spark_extensions "AshHooks,AshHooks.Endpoint,AshHooks.Subscription,AshHooks.InboundDelivery,AshHooks.InboundSource,AshHooks.OutboundDelivery,AshHooks.KeyRegistry"

  def project do
    [
      app: :ash_hooks,
      version: @version,
      # Consumers use the supported Elixir floor, not the repository's exact pin.
      # .tool-versions pins development; config/config.exs checks supported OTP.
      # CI versions also come from the root and ci/*/.tool-versions files.
      # Repository configuration is excluded from the package.
      # CI exercises the supported consumer graph.
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
        "Webhooks for Ash Framework: verify and deduplicate inbound webhooks from any sender, and sign and deliver outbound webhooks.",
      source_url: @source_url,
      homepage_url: @source_url,
      # :ecto_sql is explicit because `use AshSqlite.Repo` (test/support)
      # macro-emits Ecto.Adapters.SQL delegations; the deps-PLT app
      # enumeration does not reliably include it, and without it dialyzer
      # reports those delegations as unknown functions. :ash_postgres
      # carries the PG repo's behaviour callbacks (callback_info_missing
      # on a fresh PLT, CI 2026-10-05).
      # Shared test cases run as ordinary functions so coverage sees their code.
      # Their assertions and cleanup callbacks require ExUnit in the test PLT.
      # The documentation gate uses ExDoc's Markdown parser directly.
      dialyzer: [
        plt_add_apps: [:mix, :ash_sqlite, :ash_postgres, :ecto_sql, :ex_unit, :earmark_parser]
      ],
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
          # The sqlite test repos: AshSqlite reads min_sqlite_version/0
          # only on paths these tests never take.
          ~r/^AshHooks\.Test\.Repo$/,
          ~r/^AshHooks\.Test\.BusyRepo$/,
          ~r/^AshHooks\.Endpoint\.Url/,
          ~r/^AshHooks\.Endpoint\.SecretRef/,
          ~r/^AshHooks\.InboundDelivery\.Payload/
        ]
      ]
    ]
  end

  # The landing loop runs in the test environment so test/support compiles
  # under --warnings-as-errors too.
  def cli, do: [preferred_envs: [precommit: :test]]

  def application, do: [extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    # Optional at runtime for CONSUMERS (hex metadata), but listing them here
    # opts THIS dev build into compiling them (Mix builds a root project's own
    # optional deps). ASH_HOOKS_NO_OPTIONAL=1 drops them from the dep list
    # entirely: the CI no-optional leg uses it to prove the package compiles
    # and tests Oban/plug-free (ADR-0004).
    optional_deps =
      if System.get_env("ASH_HOOKS_NO_OPTIONAL") == "1" do
        []
      else
        [
          {:oban, "~> 2.24", optional: true},
          {:plug, "~> 1.16", optional: true},
          # A real HTTP server and a real Phoenix endpoint and router for the
          # plug's interoperability tests and the documentation's mounting
          # examples. Both depend on Plug, so they leave with it on the
          # no-optional leg; neither is a dependency of the package.
          {:bandit, "~> 1.14", only: :test},
          {:phoenix, "~> 1.8", only: :test}
        ]
      end

    [
      # Runtime
      # The Ash floor excludes releases affected by published advisories and
      # supplies the tenant inverse API. The security job scans both the locked
      # graph and the graph a consumer resolves at this floor.
      {:ash, ">= 3.37.2 and < 4.0.0-0"},
      {:splode, "~> 0.3"},
      {:spark, ">= 2.7.6 and < 3.0.0-0"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.3"}
      | optional_deps
    ] ++
      [
        # Dev/Test
        {:igniter, "~> 0.6", only: [:dev, :test], runtime: false, optional: true},
        {:ex_doc, "~> 0.31", only: [:dev, :test], runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:simple_sat, "~> 0.1", only: [:dev, :test], runtime: false},
        # SQLite supplies uniqueness and atomic conditional updates for tests.
        # This development dependency is excluded from package requirements.
        {:ash_sqlite, "~> 0.3.1", only: [:dev, :test], runtime: false},
        # Real PostgreSQL consumer tests use ASH_HOOKS_POSTGRES=1.
        # This development dependency is excluded from package requirements.
        {:ash_postgres, "~> 2.0", only: [:dev, :test], runtime: false}
      ]
  end

  defp package do
    [
      maintainers: ["rjpalermo"],
      # The documentation tree ships because shipped docs (UPGRADING.md,
      # CHANGELOG) point adopters at repo-relative paths under it. Subtrees
      # are named individually (not `documentation`) so untracked files at
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
          Enum.map(Path.wildcard("documentation/tutorials/*.md"), fn
            "documentation/tutorials/get-started.md" = path -> {path, filename: "get-started"}
            path -> path
          end) ++
          Path.wildcard("documentation/dsls/*.md") ++
          Enum.map(Path.wildcard("documentation/livebooks/*.livemd"), fn
            "documentation/livebooks/get-started.livemd" = path -> {path, filename: "guided-tour"}
            path -> path
          end),
      groups_for_extras: [
        Guides: ~r"documentation/tutorials/?",
        Livebooks: ~r"documentation/livebooks/?",
        DSLs: ~r"documentation/dsls/?"
      ],
      groups_for_modules: [
        Core: [
          AshHooks,
          AshHooks.Info,
          AshHooks.Errors,
          AshHooks.DestinationPolicy,
          AshHooks.Keyset,
          AshHooks.PrimaryKey,
          AshHooks.Ssrf,
          AshHooks.Telemetry,
          AshHooks.Tenancy
        ],
        Inbound: [
          AshHooks.BodyReader,
          AshHooks.Plug,
          AshHooks.Ingress,
          AshHooks.Inbound,
          AshHooks.InboundDelivery,
          AshHooks.InboundDelivery.LegacyAdoption,
          AshHooks.InboundSource,
          AshHooks.Inbound.ResolvedSource,
          AshHooks.Provider.DeliveryContext,
          AshHooks.InboundDelivery.Payload
        ],
        Outbound: [
          AshHooks.Event,
          AshHooks.Subscription,
          AshHooks.Endpoint,
          AshHooks.Endpoint.SecretRef,
          AshHooks.Endpoint.Url,
          AshHooks.OutboundDelivery,
          AshHooks.OutboundAttempt,
          AshHooks.OutboundEvent,
          AshHooks.EndpointHealth,
          AshHooks.Catalog,
          AshHooks.OutboundBinding,
          AshHooks.Outbound,
          AshHooks.Dispatcher,
          AshHooks.Delivery,
          AshHooks.Worker
        ],
        Signing: [
          AshHooks.Signing,
          AshHooks.Legacy,
          AshHooks.Custody,
          AshHooks.Custody.Key,
          AshHooks.Custody.PublicKey,
          AshHooks.Custody.Conformance,
          AshHooks.KeyRegistry
        ],
        "Inbound verification": [
          AshHooks.Provider,
          AshHooks.Provider.Conformance,
          AshHooks.Provider.Scheme,
          AshHooks.Provider.Signature,
          AshHooks.Provider.Event,
          AshHooks.Provider.Hmac,
          AshHooks.Provider.Mock,
          AshHooks.Provider.Mock.Event
        ],
        "HTTP adapters": [
          AshHooks.Transport,
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
      credo: ["credo --strict"],
      # Regenerates the exported `locals_without_parens` in .formatter.exs and
      # the DSL references in documentation/dsls.
      "spark.generate": [
        "spark.formatter --extensions #{@spark_extensions}",
        "run --no-start scripts/generate-dsl-docs.exs #{@spark_extensions}"
      ],
      # Fails when either generated file drifts from the DSL.
      "spark.check": [
        "spark.formatter --extensions #{@spark_extensions} --check",
        "run --no-start scripts/generate-dsl-docs.exs #{@spark_extensions} --check"
      ],
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "spark.check",
        "docs --warnings-as-errors",
        "cmd ./scripts/check-package.sh",
        # The documentation's mounting examples, compiled and run as written.
        "test test/ash_hooks/documentation_examples_test.exs"
      ]
    ]
  end
end
