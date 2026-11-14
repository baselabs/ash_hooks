defmodule AshHooks.OutboundEvent.Transformers.AddEventIdentity do
  @moduledoc false
  # Exactly one row per event id: the "record each dispatched event
  # once" identity. The consumer's migration carries the unique index.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder

  def before?(Ash.Resource.Transformers.SetPreCheckWith), do: true
  def before?(Ash.Resource.Transformers.CacheUniqueKeys), do: true
  def before?(Ash.Resource.Transformers.SetEagerCheckWith), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    Builder.add_new_identity(dsl_state, :unique_event, [:event_uuid])
  end
end
