defmodule AshHooks.MixProject do
  use Mix.Project

  @version "3.1.0"
  @source_url "https://github.com/baselabs/ash_hooks"

  def project do
    [
      app: :ash_hooks,
      version: @version,
      # CONSUMER-FACING SUPPORT WINDOW: a floor, never a pin; a library
      # must not force every consumer onto one Elixir build. Floor is 1.20
      # (owner decision 2026-09-16: nothing below 1.20 is supported); CI's
      # floor leg proves the resolver stays coherent at it. The repo's
      # OWN development runs on one pinned toolchain (.tool-versions,
      # mirrored by a dedicated CI leg) and config/config.exs refuses any
      # OTP release CI does not test; that repo-local enforcement never
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
        "Webhooks for Ash Framework: verify and deduplicate inbound webhooks from any sender, and sign and deliver outbound webhooks.",
      source_url: @source_url,
      homepage_url: @source_url,
      # :ecto_sql is explicit because `use AshSqlite.Repo` (test/support)
      # macro-emits Ecto.Adapters.SQL delegations; the deps-PLT app
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
          # The sqlite test repos: AshSqlite reads min_sqlite_version/0
          # only on paths these tests never take.
          ~r/^AshHooks\.Test\.Repo$/,
          ~r/^AshHooks\.Test\.BusyRepo$/,
          ~r/^AshHooks\.Endpoint\.Url/,
          ~r/^AshHooks\.Endpoint\.SecretRef/,
          ~r/^AshHooks\.InboundDelivery\.Payload/,
          ~r/Mix\.Tasks\.AshHooks\.Install/
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
          {:oban, "~> 2.20", optional: true},
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
      # The floor admits no Ash release with a published advisory:
      # 3.37.2 clears EEF-CVE-2026-94201 (3.34.3), -101028 (3.34.6),
      # -114214 (3.37.1) and -96581 (3.37.2), and keeps the tenant inverse
      # API the worker uses. CI's security job scans the lock a consumer
      # resolves at this floor; a new advisory against it fails there.
      {:ash, ">= 3.37.2 and < 4.0.0-0"},
      {:splode, "~> 0.3"},
      {:spark, ">= 2.3.3 and < 3.0.0-0"},
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
        # Test substrate for the fenced-ledger concurrency tests (ADR-0003
        # names sqlite as the best-effort matrix leg). Dev/test-only: never
        # ships in hex metadata, never constrains consumers. ETS was probed
        # and cannot express storage-level uniqueness or conditional-update
        # atomicity (read-then-write on both paths).
        {:ash_sqlite, "~> 0.3.1", only: [:dev, :test], runtime: false},
        # The AshPostgres consumer leg (CI's postgres job): exercises the
        # transformers against a uuid_v7-keyed, sole-store-payload consumer
        # shape: the gaps sqlite alone could not surface. Dev/test-only;
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
          AshHooks.InboundDelivery,
          AshHooks.InboundDelivery.Payload
        ],
        Outbound: [
          AshHooks.Event,
          AshHooks.Subscription,
          AshHooks.Endpoint,
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
        Signing: [AshHooks.Signing, AshHooks.Legacy],
        "Inbound verification": [
          AshHooks.Provider,
          AshHooks.Provider.Scheme,
          AshHooks.Provider.Signature,
          AshHooks.Provider.Event,
          AshHooks.Provider.Hmac,
          AshHooks.Provider.Mock
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
      # The landing loop (AGENTS.md, Build and test): every whole-tree gate,
      # no test suite and no Dialyzer.
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "spark.cheat_sheets --extensions AshHooks,AshHooks.Endpoint,AshHooks.Subscription,AshHooks.InboundDelivery,AshHooks.OutboundDelivery --check",
        "docs --warnings-as-errors",
        "cmd ./scripts/check-package.sh",
        # The documentation's mounting examples, compiled and run as written.
        "test test/ash_hooks/documentation_examples_test.exs"
      ]
    ]
  end
end
