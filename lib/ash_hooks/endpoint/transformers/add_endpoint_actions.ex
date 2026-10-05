defmodule AshHooks.Endpoint.Transformers.AddEndpointActions do
  @moduledoc false
  # Injects the durable circuit-breaker transition: `:disable` is the
  # 410 rule's durable endpoint state (ADR-0005 — an in-process fuse
  # forgets; this does not). Consumers flip it through their own surfaces
  # too; the delivery runtime drives it on 410. With `status_attribute`
  # mapped (H4) the same transition writes the CONSUMER's switch.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  # the disable change targets either the injected :status or the
  # consumer-mapped switch — the fields transformer's checks must have
  # run first; Spark's topological order does NOT follow the extension's
  # list order
  def after?(AshHooks.Endpoint.Transformers.AddEndpointFields), do: true
  def after?(_), do: false

  def transform(dsl_state) do
    switch =
      Extension.get_opt(dsl_state, [:endpoint], :status_attribute, nil) || :status

    disabled_value =
      Extension.get_opt(dsl_state, [:endpoint], :disabled_value, :disabled)

    with {:ok, change} <-
           Builder.build_action_change(Builtins.set_attribute(switch, disabled_value)) do
      with {:ok, disable} <-
             Builder.build_action(:update, :disable, accept: [], changes: [change]) do
        {:ok, Transformer.add_entity(dsl_state, [:actions], disable)}
      end
    end
  end
end
