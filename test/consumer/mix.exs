defmodule AshHooks.ConsumerVerification.MixProject do
  use Mix.Project

  def project do
    [app: :ash_hooks_consumer_verification, version: "0.0.0", elixir: "~> 1.20", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    source = System.get_env("ASH_HOOKS_CONSUMER_SOURCE") || Path.expand("../..", __DIR__)
    minimum = System.get_env("ASH_HOOKS_MINIMUM_ASH") == "1"
    ash = if minimum, do: [{:ash, "== 3.34.3", override: true}], else: []
    [{:ash_hooks, path: source} | ash]
  end
end
