defmodule AshHooks.OutboundOutbox do
  @moduledoc """
  A transactional publication ledger, separate from `AshHooks.OutboundEvent`.

  Opt in on an AshPostgres or transactional AshSqlite resource. Declare a
  primary read action, compatible attribute tenancy, and the outbound
  declarations and delivery routes that this outbox may resolve. Route names
  are stored as strings and looked up in that closed configuration; stored
  data is never converted to atoms or executable terms.

  <!-- not-run: This resource fragment needs a host repository, declaration, and worker. -->

      use Ash.Resource, extensions: [AshHooks.OutboundOutbox]

      outbox do
        declarations [{MyApp.Emitter, :changed}]
        delivery_routes default: {MyApp.Worker, :enqueue}, polling: nil
        trigger {MyApp.Worker, :enqueue_fanout}
        deduplication_horizon_seconds 604_800
      end

  Generate and apply a migration, including the tenant-leading
  `unique_publication` identity index, before publishing. PostgreSQL metadata
  uses native `json` to preserve integer and float kinds; keep that generated
  column type. Subscription filters still use `jsonb`. The extension declares
  tenant-leading partial indexes on `next_attempt_at` for pending rows and
  `failed_at` for failed rows in the data layer's migration configuration.
  The upsert requires both INSERT and UPDATE grants and row
  security policies. Host hooks, notifiers, and database triggers may issue
  additional statements beyond publish's single package statement.

  Schedule `AshHooks.fanout_pending/3` separately for every tenant. The trigger
  only reduces latency. Raw repository transactions, returned or suppressed
  notifications, and writes outside the publish action rely on that sweep.
  Inspection uses `list/2`; `prune/2` deletes only completed rows older than
  the configured deduplication horizon. Reusing an ID after pruning is a new
  publication. Failed rows remain inspectable and can be rearmed.
  """

  @section %Spark.Dsl.Section{
    name: :outbox,
    describe: "Transactional publications and their host-declared fanout routes.",
    schema: [
      declarations: [
        type: {:list, {:tuple, [:atom, :atom]}},
        required: true,
        doc: "The closed list of {resource, outbound_name} declarations this outbox resolves."
      ],
      delivery_routes: [
        type: :keyword_list,
        required: true,
        doc:
          "Named two-argument enqueue callbacks, or nil for a polling route. Names are persisted as strings."
      ],
      trigger: [
        type: {:tuple, [:atom, :atom]},
        doc:
          "Optional callback receiving (outbox_row, tenant) after physical commit. Failures leave the publication pending."
      ],
      deduplication_horizon_seconds: [
        type: :pos_integer,
        required: true,
        doc: "Minimum completed-row retention. Pruning permits later reuse of the event ID."
      ],
      fanout_timeout: [
        type: :pos_integer,
        default: 25_000,
        doc:
          "Runner deadline in milliseconds. Must be below the lease; the runner is killed at this deadline."
      ],
      fanout_lease_seconds: [
        type: :pos_integer,
        default: 30,
        doc: "Claim lease in seconds. There is no renewal."
      ],
      fanout_max_attempts: [
        type: :pos_integer,
        default: 400,
        doc: "Attempts before parking. The default capped backoff spans more than 24 hours."
      ],
      fanout_base_backoff_seconds: [
        type: :pos_integer,
        default: 2,
        doc: "Initial exponential retry delay in seconds."
      ],
      fanout_max_backoff_seconds: [
        type: :pos_integer,
        default: 240,
        doc: "Retry delay ceiling, below delivery reconciliation's default 300-second cutoff."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [AshHooks.OutboundOutbox.Transformers.AddOutbox],
    verifiers: [
      AshHooks.Verifiers.MultitenancyNoBypass,
      AshHooks.OutboundOutbox.Verifier
    ]

  @doc "Lists pending or failed publications for one tenant, oldest due first."
  @spec list(module(), keyword()) :: {:ok, [struct()]} | {:error, term()}
  defdelegate list(resource, opts \\ []), to: AshHooks.Outbox

  @doc "Deletes completed publications beyond the configured horizon; pending and failed rows survive."
  @spec prune(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate prune(resource, opts \\ []), to: AshHooks.Outbox
end
