defmodule AshHooks.InboundDelivery do
  @moduledoc """
  Turns the consumer's resource into the inbound webhook ledger — the
  durable deduplication record used by `AshHooks.Ingress`.

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
  declared scope slots, and the action primitives used by
  `AshHooks.Ingress`. These include ingest, claim/finalize/renew, payload
  redaction, bounded retention, and explicit legacy identity adoption.

  The uniqueness identity must be backed by a unique index on the
  consumer's data layer. Storage-level uniqueness preserves one ledger row
  under concurrent ingests; the lease and token govern handler ownership.
  Scope slots
  must be non-nullable attributes: a nullable slot would make `nil` scope
  values distinct on SQL unique indexes and silently break dedup for
  scope-less redeliveries.

  Provider identity upgrades use
  `AshHooks.Ingress.plan_legacy_identity_adoption/3` and
  `AshHooks.Ingress.adopt_legacy_identity/3`. Adoption keeps one deterministic
  representative per canonical identity and marks every retained sibling
  terminal `:superseded`; those rows cannot be reaped into handler execution.
  Applying adoption requires a transaction-capable data layer and quiesced
  ingress and reapers. See the ordered upgrade in `UPGRADING.md`.

  The injected actions are low-level primitives: the conditional gates
  (claim only from `:received` or an expired lease; mark/renew only by the
  current token under an unexpired lease) live in the query filters that
  `AshHooks.Ingress` builds. Call the driver APIs to preserve those
  conditions; restrict direct access to the generated machine actions.

  This ledger stores decoded provider payloads, the signed-body digest,
  event IDs, and scope keys. Payloads can contain personal information.
  Define read policies in your domain; the extension does not inject them.
  The README's Security section shows an example.
  """

  @statuses [
    :received,
    :claimed,
    :processed,
    :failed_retryable,
    :failed_permanent,
    :superseded
  ]

  @doc """
  The fenced state machine's statuses, including terminal `:superseded` rows
  retained by legacy identity adoption.
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
    verifiers: [AshHooks.Verifiers.MultitenancyNoBypass]
end
