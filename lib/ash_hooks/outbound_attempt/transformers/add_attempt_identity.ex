defmodule AshHooks.OutboundAttempt.Transformers.AddAttemptIdentity do
  @moduledoc false
  # Injects the attempt-history identity: one row per (delivery, attempt
  # number), the idempotency primitive behind the runtime's history
  # writes. The consumer's migration must carry the matching unique index.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder

  def before?(Ash.Resource.Transformers.SetPreCheckWith), do: true
  def before?(Ash.Resource.Transformers.CacheUniqueKeys), do: true
  def before?(Ash.Resource.Transformers.SetEagerCheckWith), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    Builder.add_new_identity(dsl_state, :unique_attempt, [:delivery_pk, :attempt])
  end
end
