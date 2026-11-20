defmodule AshHooks do
  @moduledoc """
  Receive, verify, and deduplicate incoming webhooks.
  Sign, deliver, retry, and track outgoing webhooks.

  Attach to a resource:


  <!-- not-run: This resource fragment requires host provider modules and configured secret storage. -->

      use Ash.Resource,
        extensions: [AshHooks]

      webhooks do
        inbound :orders do
          provider MyApp.Webhooks.OrderProvider
          secret {:app_env, [:my_app, :webhook_secret]}
          # optional: a stable event id from the decoded payload
          event_id &MyApp.Webhooks.OrderProvider.event_id/1
        end

        outbound :order_paid do
          signing_mode :dual
        end
      end

  Inbound use does not require Oban.

  Configure consistent attribute multitenancy on every resource you enable,
  including attempt history and the event log. Pass `:tenant` or `ctx[:tenant]`
  to every entry point. `AshHooks.Tenancy.resolve/2` validates the resource
  modules touched by each operation, including optional history and event logs.
  The [adoption checklist](../tutorials/tenancy-adoption-checklist.md)
  explains the transition.
  """

  @inbound %Spark.Dsl.Entity{
    name: :inbound,
    args: [:name],
    target: AshHooks.Inbound,
    describe: """
    Declares an inbound webhook source: a sender whose deliveries this
    resource receives, verifies, deduplicates, and handles.
    """,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The source identity stored in the inbound delivery ledger."
      ],
      source_record: [
        type: :module,
        doc:
          "InboundSource resource resolving provider, pause and custody keys by tenant, declaration name and cast scope. Requires record_provider_alias :on on the ledger."
      ],
      provider: [
        type: :atom,
        doc: """
        The module implementing `AshHooks.Provider`, for example one defined with
        `use AshHooks.Provider, verify: [...]`. Required for declaration-based
        keys; omit it when `source_record` selects the provider from its allowlist.
        The source name does not select a module.
        """
      ],
      body_format: [
        type: {:in, [:json, :form]},
        doc: """
        Opt-in payload decoding for this route. `:form` decodes
        application/x-www-form-urlencoded names and values without interpreting
        bracket notation. Verification still receives the exact raw bytes.
        When unset, use the provider's decoder, then its `body_format/0`, then JSON.
        JSON uses the ledger's `inbound_delivery.json_decoder`. A generated
        decoder uses that policy; otherwise `decode_payload/2` precedes a
        host-defined `decode_payload/1`.
        The request Content-Type never enables a decoder implicitly.
        """
      ],
      secret: [
        type: {:custom, AshHooks, :validate_secret_source, []},
        doc: """
        The signing-secret source: an `{M, f, a}` callback, `{:app_env, path}`,
        a 0-arity function (app-global), or a 1-arity function
        (`tenant -> {:ok, secret} | {:error, :no_webhook_secret}`) that resolves
        the TENANT's secret on multitenant ledgers. Arity dispatch on literal
        fns is unambiguous. A literal binary is rejected at parse time.
        This check catches the secret passed as the option
        value; arguments of an MFA source are the consumer's own code.
        """
      ],
      event_id: [
        type: :any,
        doc: """
        Extractor for the sender's event id from the decoded payload
        (`payload -> {:ok, id} | :error`). This explicit extractor takes precedence
        over the provider's optional `event_identity/2`, then `event_identity/1`.
        Any result other than `{:ok, id}` with a binary `id` uses the raw
        request-body digest, and an id
        longer than 255 bytes is stored as its SHA-256. Without an extractor or a
        provider callback, the raw request-body digest supplies the identity. A
        provider callback error fails closed rather than falling back to the digest.
        """
      ],
      previous_secret: [
        type: {:custom, AshHooks, :validate_secret_source, []},
        doc: """
        The ROTATED-OUT signing secret source for this inbound declaration
        (the same source shapes as `secret`): during a rotation's overlap
        window, verification falls back to this key when the current one
        does not match; both keys verify until you remove the option
        (the end of your overlap window).
        """
      ],
      paused: [
        type: {:custom, AshHooks, :validate_pause_source, []},
        doc: """
        The pause switch source (`{m, f, a}`, `{:app_env, path}`, or a
        0-arity fn, or tenant-aware 1-arity fn resolving to a boolean): while it resolves `true`,
        every request to this source is REFUSED with
        `{:error, :source_paused}` before verification or any write;
        answer 5xx from your controller to request a sender retry. Paused requests
        are not stored; recovery depends on the sender's retry policy. Unpause
        by resolving `false` again.
        """
      ],
      replay_window_seconds: [
        type: :pos_integer,
        doc: """
        Replay-protection window for providers whose scheme carries a
        trustworthy timestamp. Providers without timestamps must leave this
        unset. A directly configured provider without a timestamp header fails
        compilation (`AshHooks.Provider.timestamp_header/1` returns nil).
        A provider selected dynamically is checked at ingestion instead. The
        window value is passed to the provider's `verify_signature/3` in the context map
        for scheme-specific enforcement. For a configured provider, the window
        overrides `tolerance_seconds`.
        """
      ]
    ]
  }

  @outbound %Spark.Dsl.Entity{
    name: :outbound,
    args: [:name],
    target: AshHooks.Outbound,
    describe: """
    Declares an outbound webhook event this resource emits to subscribed
    endpoints. The event is signed with Standard Webhooks headers by default and
    delivered with retry/backoff/dead-letter semantics.
    """,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The outbound event name (e.g. `:order_paid`)."
      ],
      signing_mode: [
        type: {:in, [:legacy, :dual, :standard]},
        default: :standard,
        doc: """
        Signature headers: `:standard` sends `webhook-id`, `webhook-timestamp`,
        and `webhook-signature`; `:dual` adds the legacy `x-webhook-signature` header;
        `:legacy` sends only that legacy header.
        """
      ],
      subscriptions: [
        type: :atom,
        doc: """
        The consumer's Subscription resource module (carrying
        `AshHooks.Subscription`) this event fans out through. The
        dispatcher matches its rows against the event type.
        """
      ],
      deliveries: [
        type: :atom,
        doc: """
        The consumer's OutboundDelivery resource module (carrying
        `AshHooks.OutboundDelivery`) the dispatcher writes the durable
        per-endpoint rows into.
        """
      ],
      description: [
        type: :string,
        doc: """
        The catalog description of this event type: what it means and when
        it fires. Read back through `AshHooks.Catalog` for event pickers
        and generated docs.
        """
      ],
      example: [
        type: :string,
        doc: """
        A catalog example payload for this event type: the exact bytes
        (or a representative JSON document) shown in event pickers and
        generated docs, and sent by nothing (test sends synthesize their
        own payloads; wire your own sample through `test_send`'s
        `:payload` when you want this one on the wire).
        """
      ],
      payload_schema: [
        type: :any,
        doc: """
        The catalog's payload contract for this event type: a JSON-Schema
        map, a types module, or any term your docs renderer understands.
        Data for tooling only; the dispatcher never validates against it.
        """
      ],
      version: [
        type: :pos_integer,
        default: 1,
        doc: """
        The current payload version of this event type (default 1).
        Immediate dispatch uses this version. Outbox recovery preserves
        the version stored when the publication was accepted.
        """
      ],
      events: [
        type: :atom,
        doc: """
        The consumer's OutboundEvent resource module (carrying
        `AshHooks.OutboundEvent`): when set, every dispatch records the
        event ONCE (id, type, declared version, time, and exact payload
        bytes), whether or not any endpoint was enabled. The log has its
        own retention (`AshHooks.OutboundEvent.prune/2`) and answers
        replays (`AshHooks.OutboundEvent.replay/3`).
        """
      ],
      payload_versions: [
        type: :any,
        doc: """
        The declared variant builders map `version => {module, function}`.
        Each builder implements `f(event) :: {:ok, payload_bytes} | {:error, reason}`.
        No pin, or a pin equal to the event's payload version,
        receives the original bytes. Other declared pins run their builder;
        undeclared pins fail that endpoint closed (`:unknown_pinned_version`)
        before any row is written. Outbox recovery uses the stored payload
        version. Declare builders for every other version endpoints may pin
        while publications are pending.
        """
      ]
    ]
  }

  @webhooks %Spark.Dsl.Section{
    name: :webhooks,
    describe: """
    Webhook declarations: inbound sources and outbound events for this
    resource.
    """,
    entities: [@inbound, @outbound]
  }

  use Spark.Dsl.Extension,
    sections: [@webhooks],
    verifiers: [
      AshHooks.Verifiers.ProviderRequired,
      AshHooks.Verifiers.SourceLedger,
      AshHooks.Verifiers.ReplayWindowRequiresTimestamp,
      AshHooks.Verifiers.OutboundReferences
    ]

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.{Delivery, InboundDelivery, Ingress, OutboundDelivery}
  alias AshHooks.Errors.Unknown.UnknownError

  @doc """
  Fans an outbound event out to its subscribed endpoints. This is the outbound
  entry point, delegating to `AshHooks.Dispatcher.dispatch/4` (the
  `AshHooks.Ingress.ingest/4` twin).
  """
  @spec dispatch(module(), atom(), AshHooks.Event.t() | term(), keyword()) ::
          {:ok, [AshHooks.Dispatcher.dispatch_result()]} | {:error, term()}
  defdelegate dispatch(resource, name, event, opts \\ []), to: AshHooks.Dispatcher

  @doc """
  Accepts an event with one outbox upsert. `declaration` is `{resource, name}`;
  `:route` names a configured delivery route. Inside a transaction acceptance
  is conditional on commit. Supply `:caller_resource` and `:dynamic_repo` when
  publishing from a transaction on another resource to check atomicity before
  writing. The same connection, write repository, and instance must be used.

  Metadata must be a JSON map with string keys, at most 32 levels deep and
  1 MiB encoded. Values may be nil, booleans, signed 64-bit integers, finite
  floats except negative zero, UTF-8 strings without NUL, lists, or maps.
  Immediate dispatch retains its wider metadata domain.

  With `return_notifications?: true`, returns
  `{:ok, :accepted | :duplicate, notifications}`. Send those notifications
  after commit with `Ash.Notifier.notify/1` to deliver the hint. Host
  notifiers and host hook notifications follow Ash's ordinary rules.
  """
  @spec publish(module(), {module(), atom()}, AshHooks.Event.t(), keyword()) ::
          {:ok, :accepted | :duplicate}
          | {:ok, :accepted | :duplicate, [Ash.Notifier.Notification.t()]}
          | {:error, term()}
  defdelegate publish(outbox, declaration, event, opts \\ []), to: AshHooks.Outbox

  @typedoc """
  The outcome of one leased publication fanout. `:missing` means no row was
  visible, including rows hidden by row security; `:failed` means parked work.
  Errors preserve storage failures. The Oban worker cancels missing or failed
  publications; pending, busy, and stale work relies on the per-tenant sweep.
  """
  @type fanout_result ::
          :done | {:pending, term()} | :failed | :busy | :stale | :missing | {:error, term()}
  @typedoc "Counts of per-publication outcomes and storage errors in one bounded tenant sweep."
  @type sweep_summary :: %{
          done: non_neg_integer(),
          pending: non_neg_integer(),
          failed: non_neg_integer(),
          busy: non_neg_integer(),
          stale: non_neg_integer(),
          missing: non_neg_integer(),
          errors: [term()]
        }

  @doc """
  Claims and fans out one committed publication for `:tenant`. Refuses an
  enclosing transaction. Every attempt re-observes subscriptions and endpoints;
  existing delivery rows survive. Pending results carry a persisted retry time.
  A missing row may be absent or hidden by row security. Every call reaching
  the read emits one outbox claim event for its read or claim outcome, including
  missing and terminal reads. Acquired claims emit before work; a runner that
  loses its fenced lease also emits a stale claim event.
  The generated worker cancels missing or failed publications; it completes
  done, busy, stale, and persisted pending outcomes. No fanout job is re-enqueued:
  schedule `fanout_pending/3` for every tenant to finish pending work.
  """
  @spec fanout(module(), String.t(), keyword()) :: fanout_result()
  defdelegate fanout(outbox, event_id, opts \\ []), to: AshHooks.Outbox

  @doc """
  Sweeps a bounded batch of due publications for one tenant. Schedule this for
  every tenant even when a trigger is configured. Candidate-read errors are
  returned, and each publication's failure is isolated in the summary.
  """
  @spec fanout_pending(module(), pos_integer(), keyword()) ::
          {:ok, sweep_summary()} | {:error, term()}
  defdelegate fanout_pending(outbox, batch_size, opts \\ []), to: AshHooks.Outbox

  @doc "Rearms one failed publication for its tenant and stored ownership, resetting its attempts."
  @spec rearm(module(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  defdelegate rearm(outbox, event_id, opts \\ []), to: AshHooks.Outbox

  @doc """
  Recovers eligible outbound rows for a declaration and tenant, including
  interrupted enqueue, due retries, and expired send leases. Schedule this
  periodically for each outbound declaration and tenant; it preserves retry
  timing and attempt counts. See `AshHooks.Dispatcher.reconcile_pending/3`.
  """
  @spec reconcile_pending(module(), atom(), keyword()) ::
          {:ok, [AshHooks.Dispatcher.dispatch_result()]} | {:error, term()}
  defdelegate reconcile_pending(resource, name, opts \\ []), to: AshHooks.Dispatcher

  @typedoc """
  The per-tenant sweep totals: one result per tenant (error-isolated: one
  tenant's failure never stops the others) plus the sum of the successful
  counts.
  """
  @type sweep_totals :: %{
          results: %{optional(term()) => {:ok, non_neg_integer()} | {:error, term()}},
          total: non_neg_integer()
        }

  @doc """
  Calls `AshHooks.Ingress.reap/2` once per entry in `tenants:`, in order.
  Each call validates its tenant, and one tenant's failure does not stop the
  others. Calls run sequentially so tenant sweeps do not compete for the
  repository's shared connection pool.


  <!-- not-run: This recovery call requires a host ledger and expired claims for the listed tenants. -->

      {:ok, %{results: %{"org_a" => {:ok, 3}, "org_b" => {:ok, 0}}, total: 3}} =
        AshHooks.reap_all(Ledger, tenants: ["org_a", "org_b"])
  """
  @spec reap_all(module(), keyword()) :: {:ok, sweep_totals()}
  def reap_all(resource, opts) do
    sweep(Keyword.fetch!(opts, :tenants), fn tenant ->
      AshHooks.Ingress.reap(resource, Keyword.put(opts, :tenant, tenant))
    end)
  end

  @doc """
  Maps the retention prune over `tenants:` sequentially (routing by the
  resource's extension: inbound ledgers through `AshHooks.Ingress.prune/2`,
  outbound deliveries through `AshHooks.Delivery.prune/2`), with the same
  per-tenant isolation and sequencing as `reap_all/2`.


  <!-- not-run: This pruning call requires a host delivery resource, persisted rows, and a chosen cutoff. -->

      {:ok, %{results: %{"org_a" => {:ok, 2}}, total: 2}} =
        AshHooks.prune_all(Delivery, older_than: cutoff, tenants: ["org_a"])
  """
  @spec prune_all(module(), keyword()) :: {:ok, sweep_totals()} | {:error, term()}
  def prune_all(resource, opts) do
    with {:ok, prune} <- prune_route(resource) do
      sweep(Keyword.fetch!(opts, :tenants), fn tenant ->
        prune.(resource, Keyword.put(opts, :tenant, tenant))
      end)
    end
  end

  defp prune_route(resource) do
    extensions = ResourceInfo.extensions(resource)

    cond do
      InboundDelivery in extensions ->
        {:ok, &Ingress.prune/2}

      OutboundDelivery in extensions ->
        {:ok, &Delivery.prune/2}

      true ->
        {:error, unrouteable_resource_error(resource)}
    end
  end

  defp unrouteable_resource_error(resource) do
    UnknownError.exception(
      error:
        inspect(resource) <>
          " carries neither AshHooks.InboundDelivery nor AshHooks.OutboundDelivery, and " <>
          "prune_all routes only the package's ledgers"
    )
  end

  # Sequential per-tenant sweeps avoid exhausting the connection pool
  # and never stop on a tenant's error: an {:error, _}
  # tuple OR a crash in one tenant's sweep is carried as that tenant's
  # result (the poison-row precedent: one bad tenant must never starve the
  # rows behind it). The swept calls are the package's own reap/prune.
  # Inside a reap, a provider's parse_event_type and handle_event are
  # contained where Ingress records the handling outcome, and host code on
  # the ledger (a resource change or hook, which Ash re-raises) is contained
  # per row by Ingress's safe_redrive. Every remaining crash mode surfaces
  # as a raise in Elixir-land (incl. DBConnection's checkout/ownership
  # errors), so the sweep-level containment is a rescue.
  defp sweep(tenants, call) do
    # a repeated tenant would overwrite its own earlier result while
    # still counting into the total; deduplicate it
    {results, total} =
      Enum.reduce(Enum.uniq(tenants), {%{}, 0}, fn tenant, {results, total} ->
        case safe_call(call, tenant) do
          {:ok, count} -> {Map.put(results, tenant, {:ok, count}), total + count}
          {:error, reason} -> {Map.put(results, tenant, {:error, reason}), total}
        end
      end)

    {:ok, %{results: results, total: total}}
  end

  defp safe_call(call, tenant) do
    call.(tenant)
  rescue
    reason -> {:error, {:sweep_crashed, reason}}
  end

  @doc """
  Schema validator for the `paused` option: the same source shapes as
  `secret`, resolving to a boolean at ingest time.
  """
  @spec validate_pause_source(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_pause_source(source), do: validate_secret_source(source)

  @doc """
  Schema validator for the `secret` option: accepts only secret SOURCES,
  rejecting a literal binary at DSL parse time.
  """
  @spec validate_secret_source(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_secret_source({m, f, a} = source)
      when is_atom(m) and is_atom(f) and is_list(a),
      do: {:ok, source}

  def validate_secret_source({:app_env, path} = source) when is_list(path) do
    if path != [] and Enum.all?(path, &is_atom/1) do
      {:ok, source}
    else
      {:error, "invalid {:app_env, path}: path must be a non-empty list of atoms"}
    end
  end

  # the 1-arity fn is the TENANT-aware source (ingest resolves it with the
  # ctx tenant); arity dispatch on literal fns is unambiguous
  def validate_secret_source(source) when is_function(source, 0),
    do: {:ok, source}

  def validate_secret_source(source) when is_function(source, 1),
    do: {:ok, source}

  def validate_secret_source(source) when is_binary(source),
    do:
      {:error,
       "must be a secret SOURCE, not a literal binary: secrets live in compiled DSL data; pass {m, f, a}, {:app_env, path}, or a 0-arity function"}

  def validate_secret_source(other),
    do:
      {:error,
       "invalid secret source #{inspect(other)}: pass {m, f, a}, {:app_env, path} (non-empty atoms), or a 0/1-arity function"}
end
