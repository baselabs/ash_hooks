defmodule AshHooks.Endpoint.Transformers.AddEndpointActions do
  @moduledoc false
  # Injects the durable circuit-breaker transition: `:disable` is the
  # 410 rule's durable endpoint state (ADR-0005 — an in-process fuse
  # forgets; this does not). Consumers flip it through their own surfaces
  # too; the delivery runtime drives it on 410.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, disable} <- build_disable() do
      {:ok, Transformer.add_entity(dsl_state, [:actions], disable)}
    end
  end

  defp build_disable do
    {:ok, change} = Builder.build_action_change(Builtins.set_attribute(:status, :disabled))

    Builder.build_action(:update, :disable,
      accept: [],
      changes: [change]
    )
  end
end
