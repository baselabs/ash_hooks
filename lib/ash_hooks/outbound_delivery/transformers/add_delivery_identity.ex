defmodule AshHooks.OutboundDelivery.Transformers.AddDeliveryIdentity do
  @moduledoc false
  # Injects the effect-once delivery identity: one row per endpoint per
  # event — the same (endpoint_id, event_uuid) pair the Oban job
  # uniqueness keys use. Storage-level uniqueness on this identity is the
  # idempotency primitive; the consumer's migration must carry the
  # matching unique index.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder

  def before?(Ash.Resource.Transformers.SetPreCheckWith), do: true
  def before?(Ash.Resource.Transformers.CacheUniqueKeys), do: true
  def before?(Ash.Resource.Transformers.SetEagerCheckWith), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    Builder.add_new_identity(dsl_state, :unique_delivery, [:endpoint_id, :event_uuid])
  end
end
