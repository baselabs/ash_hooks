defmodule AshHooks.InboundDelivery do
  @moduledoc """
  Turns the consumer's resource into the inbound webhook ledger — the
  durable, fenced dedup substrate of the inbound pipeline (ADR-0003).

  Attach next to the consumer's own data layer:

      use Ash.Resource,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks, AshHooks.InboundDelivery]

      inbound_delivery do
        scope_identity([:account_id])
      end

  The extension injects the ledger fields (provider, external ids, payload +
  digest, the fenced state machine's status/token/lease/attempts), the
  `unique_ingest` identity spanning provider + external event id + the
  declared scope slots, and the fenced action primitives (`:ingest`,
  `:claim`, `:mark_processed`, `:mark_failed`, `:renew`).

  The uniqueness identity must be backed by a REAL unique index on the
  consumer's data layer — storage-level uniqueness is the idempotency
  primitive, and the fenced machine's crash-safety rests on it. Scope slots
  must be non-nullable attributes: a nullable slot would make `nil` scope
  values distinct on SQL unique indexes and silently break dedup for
  scope-less redeliveries.

  The injected actions are PRIMITIVES, not fences: the conditional gates
  (claim only from `:received` or an expired lease; mark/renew only by the
  current token under an unexpired lease) live in the query filters that
  `AshHooks.Ingress` builds — the WHERE clause is the portable fence
  (probe 2026-08-21: `error()`-in-expression atomics are inexpressible on
  sqlite, and action-level `change filter(...)` is silently dropped on the
  atomic path).

  READ EXPOSURE: this ledger stores RAW provider payloads (third-party
  PII), event ids, and scope keys. The package injects NO read policies —
  read access is governed ENTIRELY by the consumer's own domain policies.
  Mount the ledger behind policies that deny reads by default and open
  them explicitly (README → Security has the recipe).
  """

  @statuses [:received, :claimed, :processed, :failed_retryable, :failed_permanent]

  @doc """
  The fenced state machine's statuses, in lifecycle order.
  """
  @spec statuses() :: list(atom())
  def statuses, do: @statuses

  @scope %Spark.Dsl.Section{
    name: :inbound_delivery,
    describe: """
    Configuration of this resource as the inbound webhook ledger.
    """,
    schema: [
      scope_identity: [
        type: {:list, :atom},
        default: [],
        doc: """
        Consumer-declared attributes extending the unique-ingest identity.
        Provider event ids are not globally unique (across accounts etc.), so
        the identity is `[#{inspect(:provider)}, #{inspect(:external_event_id)} | scope_identity]`.
        Each slot must be a non-nullable attribute on this resource (verifier
        rejects otherwise) and its value must be supplied on every ingest.
        """
      ],
      lease_seconds: [
        type: :pos_integer,
        default: 30,
        doc: """
        Default claim lease duration. When a claim's lease expires the row
        becomes claimable again (reaper path) — the stale owner can no
        longer mark it.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@scope],
    transformers: [
      AshHooks.InboundDelivery.Transformers.AddLedgerFields,
      AshHooks.InboundDelivery.Transformers.AddLedgerIdentity,
      AshHooks.InboundDelivery.Transformers.AddFencedActions
    ],
    verifiers: []
end
