defmodule AshHooks.InboundDelivery.Transformers.AddLedgerIdentity do
  @moduledoc false
  # Injects the unique-ingest identity spanning provider, external event id,
  # and the consumer-declared scope slots. Storage-level uniqueness on this
  # identity is the idempotency primitive (ADR-0003) — the consumer's
  # migration must carry the matching unique index.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Extension

  def before?(Ash.Resource.Transformers.SetPreCheckWith), do: true
  def before?(Ash.Resource.Transformers.CacheUniqueKeys), do: true
  def before?(Ash.Resource.Transformers.SetEagerCheckWith), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    scope =
      Extension.get_opt(dsl_state, [:inbound_delivery], :scope_identity, [])

    Builder.add_new_identity(
      dsl_state,
      :unique_ingest,
      [:provider, :external_event_id | scope]
    )
  end
end
