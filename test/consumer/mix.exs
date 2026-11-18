defmodule AshHooks.ConsumerVerification.MixProject do
  use Mix.Project

  def project do
    [app: :ash_hooks_consumer_verification, version: "0.0.0", elixir: "~> 1.20", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  # A production consumer at the declared floors. The committed lock is the
  # graph CI compiles and scans; refresh it with `MIX_ENV=prod mix deps.get`
  # here when the floors or the package requirements change.
  defp deps do
    [
      {:ash_hooks, path: Path.expand("../..", __DIR__)},
      {:ash, "== 3.37.2", override: true},
      {:spark, "== 2.7.6", override: true}
    ]
  end
end
