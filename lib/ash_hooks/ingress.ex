defmodule AshHooks.Ingress do
  @moduledoc """
  The inbound pipeline driver: verify → ingest → claim → handle → mark,
  over a ledger resource carrying the `AshHooks.InboundDelivery` extension.

  `AshHooks.Plug` is the HTTP entry point. `ingest/4` is the lower-level sync
  entry point for custom transports and pipelines, called with the exact raw
  request body. Capture it pre-parser via `AshHooks.BodyReader`, or read it
  before any parser consumes it; parsed params cannot recover those bytes.
  Request context carries the
  signature, request headers, public request method/URI, scope, connection,
  and tenant. It does not accept or forward a request-controlled clock;
  replay-window verification uses the runtime system clock. The machine's
  crash-safety contract:

    * the decoded payload persists before handling; `payload_digest` binds
      it to the signed raw bytes;
    * a verified body that cannot decode to a map or list is stored by
      `:record_malformed` once its event identity resolves, with placeholder
      payload `%{}`, status `:failed_permanent`, and error class
      `"malformed_payload"`. A provider identity callback that rejects the
      placeholder refuses the request before `:record_malformed` runs (with
      `ingress_tracking :on`, ingress attempts to record the refusal as a
      rejection row). A newly created malformed row is never claimed
      or handled; its attempts and fencing token stay 0. A duplicate still
      drives the surviving row's stored payload;
    * the unique index preserves one row per provider/event/scope identity.
      With the injected writable UUID key, the surviving key distinguishes
      `:created` from `:duplicate`. Custom generated keys use a pre-read;
      concurrent first arrivals may both be reported as `:created`, while
      the stored row and claim remain deduplicated;
    * a claim is a WHERE-gated update (`status == :received`, a
      retryable failure, or an expired lease) that bumps the monotonic
      fencing token, allowing redelivery to recover a stranded row;
    * marks are gated on the caller's token and an unexpired lease; a
      stale owner (superseded or expired) is rejected.

  Returns `{:ok, :created | :duplicate, delivery}`; the delivery's
  `status` carries the outcome (`:processed`, `:failed_retryable`,
  `:failed_permanent`, or retained `:superseded`). Returned retry and permanent
  failures are recorded. Verification and configuration failures do not run the
  handler. With `ingress_tracking :on`, ingress may attempt a rejection-row
  write before returning the error. Paused sources, unavailable custody keys,
  and unrecognized callback failures do not create rejection rows or increase
  the failed-verification count.

  The individual machine steps (`ingest_delivery/2`, `claim_delivery/3`,
  `mark_processed/4`, `mark_failed/6`, `renew/4`, `reap/2`) are public for
  composition and monitoring; a consumer-driven async pipeline (your own
  202-then-claim flow) and the reaper drive the same steps. Each accepts
  the tenancy options; the arities from before 1.2.0 (one fewer argument) keep
  working for single-tenant ledgers.

  Internal ledger operations use `authorize?: false`; callers must restrict
  access to these machine functions. Signature verification gates the sync
  ingest path. Your domain policies govern application read access to decoded
  provider payloads and signed-body digests. See the README's retention and security section.
  The returned row can remain `:received` or `:claimed` when this call did not
  obtain ownership. Inspect its status before choosing an HTTP acknowledgment.
  Handler and claimed-receipt parser exceptions, exits, and throws are recorded as
  `:failed_retryable` with error class `"handler_crashed"`, using the current
  claim's fencing token. Both synchronous ingestion and reaping use this path.
  Any handler result outside `{:ok, value}` or a retry/permanent error triple,
  and any unexpected parser result, records `"invalid_handler_result"` as a
  retryable failure. Each recorded failure emits the ingress failure event;
  a stale owner reloads without recording or emitting a failure.
  """

  require Ash.Query

  alias AshHooks.{Custody, Errors, Info, Phase, PrimaryKey, Provider, Tenancy}

  alias AshHooks.Errors.Invalid.{
    InvalidSignature,
    MalformedPayload,
    NoWebhookSecret,
    UnknownSource
  }

  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.Inbound.ResolvedSource
  alias AshHooks.KeyRegistry.Storage
  alias AshHooks.Provider.DeliveryContext
  alias Spark.Dsl.Extension

  @typedoc """
  The request context. `:signature` is the signature header value for
  providers whose `signature_source/0` is `:header` (the default); `:headers`
  carries the request headers, preferably as the ordered `{name, value}` list
  Plug provides in `conn.req_headers`, or as a map; `:method` and `:request_uri`
  must reproduce the public request values covered by the provider signature;
  `:scope` carries values for the ledger's declared `scope_identity` slots;
  `:connection` is the per-connection provider's secret source argument; and
  `:tenant` is required on multitenant ledgers. Ingress constructs the
  provider verification context from these known keys and never forwards an
  input `:now_ms` clock override. Optional `:host_context` is passed only to
  verification, without persistence or inspection. The provider remains
  responsible for binding any upstream proof to this body, tenant and source.
  """
  @type ctx :: %{
          optional(:signature) => String.t(),
          optional(:headers) =>
            [{String.t(), String.t()}] | %{optional(String.t()) => String.t()},
          optional(:method) => String.t() | nil,
          optional(:request_uri) => String.t() | nil,
          optional(:connection) => term(),
          optional(:host_context) => term(),
          optional(:scope) => %{optional(atom() | String.t()) => term()},
          optional(:tenant) => term()
        }

  @lease_default_seconds 30
  @prune_default_batch_size 100
  @prune_max_batch_size 1_000

  @doc "Builds the legacy provider-identity adoption audit without writing rows."
  @spec plan_legacy_identity_adoption(module(), atom(), keyword()) ::
          {:ok, AshHooks.InboundDelivery.LegacyAdoption.plan()} | {:error, term()}
  defdelegate plan_legacy_identity_adoption(resource, name, opts \\ []),
    to: AshHooks.InboundDelivery.LegacyAdoption,
    as: :plan

  @doc "Applies one reviewed, quiesced provider-identity adoption partition."
  @spec adopt_legacy_identity(module(), atom(), keyword()) ::
          {:ok, AshHooks.InboundDelivery.LegacyAdoption.plan()} | {:error, term()}
  defdelegate adopt_legacy_identity(resource, name, opts \\ []),
    to: AshHooks.InboundDelivery.LegacyAdoption,
    as: :apply

  # ────────────────────────── sync pipeline ──────────────────────────

  @doc """
  Lists inbound deliveries by filter with keyset pagination (newest
  first), providing the inbound delivery log.

  Options: `:source` (the inbound declaration's name, e.g. `:orders`),
  `:status` (a list of `AshHooks.InboundDelivery.statuses/0`),
  `:event_type`, `:from` / `:to` (`DateTime` bounds on `inserted_at`),
  `:limit` (default 50, max 500), `:after` (the previous page's cursor),
  and `:tenant`. The resource needs `timestamps()` and an `:id`.
  Returns `{:ok, %{records:, next_cursor:}}`.
  """
  @spec list(module(), keyword()) ::
          {:ok, %{records: [struct()], next_cursor: binary() | nil}} | {:error, term()}
  def list(resource, opts \\ []) do
    alias AshHooks.{Keyset, Tenancy}

    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- require_list_columns(resource) do
      Keyset.read_page(resource, opts, :inserted_at, &list_filters(&1, opts), tenant)
    end
  end

  defp require_list_columns(resource) do
    cond do
      is_nil(Ash.Resource.Info.attribute(resource, :inserted_at)) ->
        {:error,
         UnknownError.exception(
           error:
             inspect(resource) <>
               " has no :inserted_at; add `timestamps()` to its attributes " <>
               "(and the columns to its migration) to use the list queries"
         )}

      is_nil(Ash.Resource.Info.attribute(resource, :id)) ->
        {:error,
         UnknownError.exception(
           error:
             inspect(resource) <>
               " has no :id attribute, which keyset pagination's tiebreak requires"
         )}

      true ->
        :ok
    end
  end

  defp list_filters(query, opts) do
    query
    |> ingress_eq(:provider, opts[:source])
    |> ingress_eq(:external_event_type, opts[:event_type])
    |> ingress_status(opts[:status])
    |> ingress_time_range(opts[:from], opts[:to])
  end

  defp ingress_eq(query, _field, nil), do: query

  defp ingress_eq(query, field, value) do
    require Ash.Expr
    ref = Ash.Expr.ref(field)
    expression = Ash.Expr.expr(^ref == ^value)
    Ash.Query.filter(query, ^expression)
  end

  defp ingress_status(query, nil), do: query

  defp ingress_status(query, statuses) when is_list(statuses) do
    require Ash.Expr
    ref = Ash.Expr.ref(:status)
    expression = Ash.Expr.expr(^ref in ^statuses)
    Ash.Query.filter(query, ^expression)
  end

  defp ingress_time_range(query, nil, nil), do: query

  defp ingress_time_range(query, from, to) do
    require Ash.Expr
    time = Ash.Expr.ref(:inserted_at)

    lower = if from, do: Ash.Expr.expr(^time >= ^from)
    upper = if to, do: Ash.Expr.expr(^time <= ^to)

    expression =
      case {lower, upper} do
        {one, nil} -> one
        {nil, one} -> one
        {lower, upper} -> Ash.Expr.expr(^lower and ^upper)
      end

    Ash.Query.filter(query, ^expression)
  end

  @doc """
  Counts the inbound story over a window (`:from` / `:to` on
  `inserted_at`, inclusive; `:source` optional; `:tenant` applies):


  <!-- not-run: These sample counts require a host ledger with stored receipts and a selected time range. -->

      {:ok,
       %{received: 120, processed: 100, duplicates: 18, failed_verification: 2, handler_failures: 3}} =
        AshHooks.Ingress.counts(MyApp.Ledger, from: an_hour_ago)

  `received` counts the window's accepted rows (rejection rows are excluded
  because a refused request was never received); `processed` and
  `handler_failures` (`:failed_retryable` + `:failed_permanent`) come off
  the statuses. `duplicates` and `failed_verification` require
  `ingress_tracking :on` on the ledger (the `duplicates` counter column
  and the payload-less `:failed_verification` rejection rows); without
  them both report 0. Paused sources, unavailable custody keys, and
  unrecognized callback failures are excluded from rejection rows and their count.
  Window counts run as data-layer count and sum aggregates, without loading
  ledger rows or payloads into application memory. A storage read failure returns `{:error, reason}`; zero counts mean the read
  succeeded and found no matching observations.
  """
  @spec counts(module(), keyword()) ::
          {:ok,
           %{
             received: non_neg_integer(),
             processed: non_neg_integer(),
             duplicates: non_neg_integer(),
             failed_verification: non_neg_integer(),
             handler_failures: non_neg_integer()
           }}
          | {:error, term()}
  def counts(resource, opts \\ []) do
    alias AshHooks.Tenancy

    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- require_timestamps(resource),
         {:ok, counts} <- window_counts(resource, opts, tenant) do
      {:ok, Map.merge(%{duplicates: 0, failed_verification: 0}, counts)}
    end
  end

  defp require_timestamps(resource) do
    if Ash.Resource.Info.attribute(resource, :inserted_at) do
      :ok
    else
      {:error,
       UnknownError.exception(
         error:
           inspect(resource) <>
             " has no :inserted_at; add `timestamps()` to its attributes " <>
             "(and the columns to its migration) to use the window counts"
       )}
    end
  end

  defp window_counts(resource, opts, tenant) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    from = Keyword.get(opts, :from) || DateTime.add(now, -86_400, :second)
    to = Keyword.get(opts, :to) || now

    AshHooks.Phase.run(
      resource
      |> Ash.Query.filter(inserted_at >= ^from and inserted_at <= ^to)
      |> then(fn query ->
        if opts[:source], do: ingress_eq(query, :provider, opts[:source]), else: query
      end),
      tenant,
      &Ash.aggregate(&1, count_aggregates(resource), authorize?: false, tenant: tenant)
    )
  rescue
    error -> {:error, Ash.Error.to_error_class(error)}
  end

  defp count_aggregates(resource) do
    counts = [
      {:received, :count, query: [filter: [status: [not_eq: :failed_verification]]]},
      {:processed, :count, query: [filter: [status: :processed]]},
      {:handler_failures, :count,
       query: [filter: [status: [in: [:failed_retryable, :failed_permanent]]]]}
    ]

    if Extension.get_opt(resource, [:inbound_delivery], :ingress_tracking, :off) == :on do
      [
        {:failed_verification, :count, query: [filter: [status: :failed_verification]]},
        {:duplicates, :sum, field: :duplicates, default: 0}
        | counts
      ]
    else
      counts
    end
  end

  @doc """
  Drives one inbound delivery through the full sync pipeline. The tenant
  rides the ctx (`ctx[:tenant]`) and threads every ledger call; the
  dedup identity, the claim fence, and every mark are per-tenant.
  """
  @spec ingest(module(), atom(), binary() | nil, ctx()) ::
          {:ok, :created | :duplicate, struct()} | {:error, term()}
  def ingest(resource, name, raw_body, ctx) do
    started = System.monotonic_time()

    with {:ok, tenant} <- Tenancy.resolve([resource], ctx[:tenant]),
         {:ok, env} <- verify(resource, name, raw_body, Map.put(ctx, :tenant, tenant), started),
         {:ok, created?, delivery} <- ingest_delivery(resource, env) do
      drive(resource, env, delivery, created?)
    end
  end

  # the verify event wraps resolution + signature verification; the
  # reason is the fixed error class atom, never the raw error payload.
  defp verify(resource, name, raw_body, ctx, started) do
    case resolve(resource, name, raw_body, ctx) do
      {:ok, _env} = ok ->
        emit_verify(name, :ok, nil, started)
        ok

      {:error, reason} ->
        emit_verify(name, :invalid, verify_error_class(reason), started)
        record_rejection(resource, name, raw_body, ctx, reason)
        {:error, reason}
    end
  end

  # a paused source is an operator state, not a failed verification; the
  # verify telemetry keeps its honest label and no rejection row records
  defp verify_error_class(:source_paused), do: :source_paused
  defp verify_error_class(error), do: error_class(error)

  # The failed-verification rejection row (ingress_tracking :on): the
  # digest identity (repeated bad deliveries dedup), a CONSTANT payload
  # marker (never the unverified request bytes) and the count surface
  # behind counts/2. Failures here never change the refusal outcome.
  defp record_rejection(_resource, _name, _raw_body, _ctx, :source_paused), do: :ok

  defp record_rejection(_resource, _name, _raw_body, _ctx, %module{})
       when module in [AshHooks.Errors.Unknown.KeyUnavailable, UnknownError], do: :ok

  defp record_rejection(resource, name, raw_body, ctx, _reason) do
    if Ash.Resource.Info.action(resource, :record_rejection) do
      input =
        %{
          provider: name,
          external_event_id: "verify:" <> content_digest(raw_body || ""),
          external_event_type: nil,
          payload: Jason.encode!(%{"rejected" => true}),
          payload_digest: content_digest(raw_body || "")
        }
        |> Map.merge(Map.new(ctx[:scope] || %{}))

      _ =
        AshHooks.Phase.run(
          resource,
          ctx[:tenant],
          &Ash.create(&1.resource, input,
            context: AshHooks.Phase.context(resource),
            action: :record_rejection,
            authorize?: false,
            tenant: ctx[:tenant]
          )
        )
    end

    :ok
  end

  defp emit_verify(source, outcome, reason, started) do
    :telemetry.execute(
      [:ash_hooks, :ingress, :verify],
      %{
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
      },
      %{source: source, outcome: outcome, reason: reason}
    )
  end

  for {module, token} <- [
        {AshHooks.Errors.Invalid.InvalidSignature, :invalid_signature},
        {AshHooks.Errors.Invalid.NoWebhookSecret, :no_webhook_secret},
        {AshHooks.Errors.Invalid.StaleTimestamp, :stale_timestamp},
        {AshHooks.Errors.Invalid.UnknownEventType, :unknown_event_type},
        {AshHooks.Errors.Invalid.MalformedPayload, :malformed_payload},
        {AshHooks.Errors.Invalid.UnknownSource, :unknown_source},
        {AshHooks.Errors.Invalid.KeyKindMismatch, :key_kind_mismatch},
        {AshHooks.Errors.Invalid.UnknownKey, :unknown_key},
        {AshHooks.Errors.Unknown.KeyUnavailable, :key_unavailable}
      ] do
    defp error_class(%unquote(module){}), do: unquote(token)
  end

  defp error_class(_), do: :unknown_error

  # The duplicate counter (ingress_tracking :on): bumped on every
  # duplicate ingest through the gated machine action; failures never
  # change the duplicate outcome
  defp count_duplicate(resource, delivery, tenant) do
    if Ash.Resource.Info.action(resource, :count_duplicate) do
      _ =
        AshHooks.Phase.bulk(
          resource
          |> Ash.Query.do_filter(AshHooks.PrimaryKey.filter(delivery)),
          tenant,
          &Ash.bulk_update(&1, :count_duplicate, %{},
            authorize?: false,
            return_records?: false,
            return_errors?: false,
            strategy: [:atomic],
            tenant: tenant
          )
        )

      :ok
    end
  end

  @doc """
  Persists the decoded payload and signed-body digest before handling via the
  no-touch unique upsert. Returns `{:ok, created?, row}` or `{:error, reason}`.
  For a writable `:id` primary key, compares the surviving ID with a fresh
  client-generated ID. Other primary keys use a preliminary identity read;
  concurrent inserts or rows hidden by a read filter can be reported as created
  even when the database upsert deduplicates them. The env carries the resolved
  tenant (`env[:tenant]`). `env[:decode_result]` is `:ok` for decoded payloads
  (the default when omitted), or `{:error, :malformed_payload}` to record a
  terminal malformed row via `:record_malformed`. Both actions preserve the
  surviving row on conflict and share duplicate classification and telemetry.
  """
  @spec ingest_delivery(module(), map()) :: {:ok, boolean(), struct()} | {:error, term()}
  def ingest_delivery(resource, env) do
    with {:ok, tenant} <- Tenancy.resolve([resource], env[:tenant]) do
      ingest_delivery!(resource, env, tenant)
    end
  end

  defp ingest_delivery!(resource, env, tenant) do
    input =
      %{
        provider: env.name,
        external_event_id: env.external_event_id,
        external_event_type: env.type_string,
        payload: env.payload,
        payload_digest: env.digest
      }
      |> Map.merge(env.scope)

    input =
      if record_provider_alias?(resource),
        do: Map.put(input, :provider_alias, env[:provider_alias]),
        else: input

    input =
      if Extension.get_opt(resource, [:inbound_delivery], :record_verified_facts, :off) == :on,
        do: Map.put(input, :verified_facts, env[:verified_facts]),
        else: input

    if AshHooks.Info.writable_id?(resource) and Ash.Resource.Info.primary_key(resource) == [:id] do
      ingest_with_supplied_id(resource, input, env, tenant)
    else
      # A custom/generated PK cannot use the supplied UUID classification,
      # so classification pre-reads the unique_ingest
      # identity instead. Exact in every sequential case (provider
      # redeliveries) and whenever the primary read can see the existing
      # row (a base-filtered read that hides it classifies :created).
      # The storage upsert still deduplicates the row. The claim rejects a
      # terminal or currently leased row; handler invocation remains
      # at-least-once across crashes or lease expiry.
      ingest_with_pre_read(resource, input, env, tenant)
    end
  end

  defp ingest_with_supplied_id(resource, input, env, tenant) do
    id = Ash.UUID.generate()
    input = Map.put(input, :id, id)

    AshHooks.Contention.run(fn ->
      case AshHooks.Phase.run(
             resource,
             tenant,
             &Ash.create(&1.resource, input,
               context: AshHooks.Phase.context(resource),
               action: ingest_action(env),
               authorize?: false,
               tenant: tenant
             )
           ) do
        {:ok, delivery} ->
          classify_and_emit(env, delivery.id == id, delivery)

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  defp ingest_with_pre_read(resource, input, env, tenant) do
    case fetch_ingested(resource, env, tenant) do
      {:ok, delivery} -> classify_and_emit(env, false, delivery)
      :missing -> pre_read_create(resource, input, env, tenant)
      {:error, error} -> {:error, error}
    end
  end

  defp pre_read_create(resource, input, env, tenant) do
    AshHooks.Contention.run(fn ->
      AshHooks.Phase.run(
        resource,
        tenant,
        &Ash.create(&1.resource, input,
          context: AshHooks.Phase.context(resource),
          action: ingest_action(env),
          authorize?: false,
          tenant: tenant
        )
      )
    end)
    |> case do
      {:ok, delivery} -> classify_and_emit(env, true, delivery)
      {:error, error} -> {:error, error}
    end
  end

  defp ingest_action(%{decode_result: {:error, :malformed_payload}}), do: :record_malformed
  defp ingest_action(_env), do: :ingest

  # the pre-read matches the FULL unique_ingest identity in SQL (provider
  # + external_event_id + every scope slot): filtering the scope in
  # memory would read every sibling scope's row for the same external id
  # into the process; scope slots exist precisely because external ids
  # repeat across accounts/connections
  defp fetch_ingested(resource, env, tenant) do
    result =
      AshHooks.Contention.run(fn ->
        AshHooks.Phase.run(
          resource
          |> Ash.Query.do_filter(
            [provider: env.name, external_event_id: env.external_event_id] ++
              Map.to_list(env.scope)
          ),
          tenant,
          &Ash.read_one(&1, authorize?: false, tenant: tenant)
        )
      end)

    case result do
      {:ok, nil} -> :missing
      {:ok, row} -> {:ok, row}
      {:error, error} -> {:error, error}
    end
  end

  defp classify_and_emit(env, created?, delivery) do
    if created? == false, do: count_duplicate(delivery.__struct__, delivery, env[:tenant])

    :telemetry.execute(
      [:ash_hooks, :ingress, :dedup],
      %{},
      %{source: env.name, outcome: if(created?, do: :created, else: :duplicate)}
    )

    if created? and delivery.status == :failed_permanent, do: emit_failure(delivery)
    {:ok, created?, delivery}
  end

  defp emit_failure(row) do
    :telemetry.execute(
      [:ash_hooks, :ingress, :failure],
      %{count: 1},
      %{
        source: row.provider,
        error_class: row.error_class,
        permanent?: row.status == :failed_permanent
      }
    )
  end

  @doc """
  Claims a delivery: WHERE-gated on `status == :received`, a re-driveable
  failure, or an EXPIRED lease. Bumps the fencing token atomically and
  takes a fresh lease. A live foreign lease (or a terminal row) returns
  `{:error, :lease_held}`. `:tenant` scopes the claim (required on
  multitenant ledgers).
  """
  @spec claim_delivery(module(), term(), keyword()) ::
          {:ok, non_neg_integer(), struct()} | {:error, :lease_held | term()}
  def claim_delivery(resource, delivery_id, opts \\ []),
    do: claim(resource, delivery_id, opts, nil)

  defp claim(resource, delivery_id, opts, adoption_alias) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         {:ok, key} <- normalize_primary_key(resource, delivery_id) do
      # `now` and the lease are recomputed on EVERY attempt: a retry that
      # spends contention time sleeping must not grant a lease that is
      # shorter than configured or already expired.
      result =
        AshHooks.Contention.run(fn ->
          attempt_now = now()
          lease_expires_at = DateTime.add(attempt_now, lease_seconds(resource), :second)

          AshHooks.Phase.bulk(
            resource
            |> Ash.Query.do_filter(key)
            |> claim_alias_filter(adoption_alias)
            |> Ash.Query.filter(
              status == :received or status == :failed_retryable or
                (status == :claimed and lease_expires_at < ^attempt_now)
            ),
            tenant,
            &Ash.bulk_update(&1, :claim, %{lease_expires_at: lease_expires_at},
              authorize?: false,
              return_records?: true,
              return_errors?: true,
              strategy: [:atomic],
              tenant: tenant,
              atomic_update: adoption_update(adoption_alias)
            )
          )
        end)

      case result do
        %Ash.BulkResult{status: :success, records: [delivery]} ->
          :telemetry.execute(
            [:ash_hooks, :ingress, :claim],
            %{},
            %{source: delivery.provider, outcome: :claimed}
          )

          {:ok, delivery.fencing_token, delivery}

        %Ash.BulkResult{status: :success, records: []} ->
          :telemetry.execute(
            [:ash_hooks, :ingress, :claim],
            %{},
            %{source: nil, outcome: :lease_held}
          )

          {:error, :lease_held}

        %Ash.BulkResult{errors: [error | _]} ->
          {:error, error}
      end
    end
  end

  @doc """
  Retention hook: deletes one bounded batch of TERMINAL ledger rows
  (`:processed`, `:failed_permanent`, `:superseded`) older than `older_than`, by the resource's
  `inserted_at` (add Ash `timestamps()` to the resource and its
  migration). Non-terminal rows are never deleted; retryable and
  lease-held deliveries keep their dedup identity and re-drive path.

  Deleting a terminal row re-opens its dedup identity: a replayed
  delivery of the same webhook processes again (inbound), and on the
  outbound side, a re-emission of the same event re-dispatches and
  double-sends. Set the TTL beyond any replay/re-emission horizon.
  `:batch_size` defaults to 100 and is capped at 1,000. Only primary-key
  columns are selected before deletion. Returns `{:ok, deleted_count}` for
  this batch; call again until it returns a count below the requested size.
  """
  @spec prune(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(resource, opts) do
    older_than = normalize_cutoff(Keyword.fetch!(opts, :older_than))
    batch_size = Keyword.get(opts, :batch_size, @prune_default_batch_size)

    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         :ok <- require_timestamps!(resource),
         :ok <- validate_prune_batch_size(batch_size) do
      require Ash.Query

      primary_key = Ash.Resource.Info.primary_key(resource)

      result =
        AshHooks.Contention.run(fn ->
          AshHooks.Phase.bulk(
            resource
            |> Ash.Query.filter(
              status in [:processed, :failed_permanent, :superseded] and
                inserted_at < ^older_than
            )
            |> Ash.Query.sort(primary_key)
            |> Ash.Query.limit(batch_size)
            |> Ash.Query.select(primary_key),
            tenant,
            &Ash.bulk_destroy(&1, :prune, %{},
              authorize?: false,
              return_records?: true,
              return_errors?: true,
              strategy: [:atomic],
              tenant: tenant
            )
          )
        end)

      case result do
        %Ash.BulkResult{status: :success, records: rows} -> {:ok, length(rows)}
        %Ash.BulkResult{errors: [error | _]} -> {:error, error}
      end
    end
  end

  @doc """
  Retention field-redaction hook: replaces the stored payload of a
  CLAIMED delivery with `redactor.(payload)` under the caller's token
  and an unexpired lease (the `mark_processed/3` fence). The row keeps
  its dedup identity; only the payload changes. `payload_digest` is
  deliberately NOT updated (it binds the ORIGINAL signed bytes for the
  audit trail).

  The redactor (`{m, f}` | 1-arity fun) receives the stored payload
  (map or list, including event batches) and returns the
  replacement (same type) or nil to leave it unchanged. A crashing or
  invalid redactor returns an error and leaves the payload UNCHANGED
  (preserving the audit record so the caller may retry). Redact,
  then mark promptly: a lease expiry between redact and mark re-drives
  the row with the redacted payload.
  """
  @spec redact_payload(module(), term(), non_neg_integer(), term(), keyword()) ::
          :ok | {:error, :stale_token | :redactor_crash | :invalid_redactor_result | term()}
  def redact_payload(resource, delivery_id, token, redactor, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         {:ok, key} <- normalize_primary_key(resource, delivery_id),
         {:ok, delivery} <- read_by_key(resource, key, tenant),
         # the fence is checked BEFORE the redactor sees the payload; a
         # stale token must not receive sensitive bytes through the
         # callback even though the eventual write would be rejected
         #
         :ok <- check_fence(delivery, token) do
      apply_redactor(redactor, delivery.payload, resource, key, token, tenant)
    end
  end

  defp check_fence(delivery, token) do
    if fence_valid?(delivery, token), do: :ok, else: {:error, :stale_token}
  end

  defp fence_valid?(delivery, token) do
    delivery.fencing_token == token and delivery.status == :claimed and
      DateTime.compare(delivery.lease_expires_at, now()) == :gt
  end

  defp apply_redactor(redactor, payload, resource, delivery_id, token, tenant) do
    case redactor_fun(redactor).(payload) do
      nil ->
        :ok

      new_payload when is_map(new_payload) or is_list(new_payload) ->
        gated_update(
          resource,
          delivery_id,
          token,
          :redact_payload,
          %{payload: new_payload},
          tenant
        )

      _other ->
        {:error, :invalid_redactor_result}
    end
  rescue
    _ -> {:error, :redactor_crash}
  catch
    :exit, _ -> {:error, :redactor_crash}
    :throw, _ -> {:error, :redactor_crash}
  end

  defp redactor_fun({m, f}) when is_atom(m) and is_atom(f), do: &apply(m, f, [&1])
  defp redactor_fun(fun) when is_function(fun, 1), do: fun

  # sqlite stores timestamps as ISO8601 TEXT compared LEXICALLY; a
  # second-truncated cutoff would sort AFTER same-second usec rows and
  # delete them early. Normalizing to microsecond precision keeps the
  # lexical and chronological orders identical (adversarial finding).
  defp normalize_cutoff(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp require_timestamps!(resource) do
    if Ash.Resource.Info.attribute(resource, :inserted_at) do
      :ok
    else
      {:error,
       UnknownError.exception(
         error:
           inspect(resource) <>
             " has no :inserted_at; add `timestamps()` to its attributes " <>
             "(and the inserted_at/updated_at columns to its migration) to use the retention hooks"
       )}
    end
  end

  defp validate_prune_batch_size(size)
       when is_integer(size) and size > 0 and size <= @prune_max_batch_size,
       do: :ok

  defp validate_prune_batch_size(_size) do
    {:error,
     UnknownError.exception(
       error: "batch_size must be an integer from 1 through #{@prune_max_batch_size}"
     )}
  end

  @doc """
  Marks a claimed delivery processed, gated on the caller's token under an
  unexpired lease. `:tenant` scopes the mark (required on multitenant
  ledgers).
  """
  @spec mark_processed(module(), term(), non_neg_integer(), keyword()) ::
          :ok | {:error, :stale_token | term()}
  def mark_processed(resource, delivery_id, token, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      gated_update(resource, delivery_id, token, :mark_processed, %{}, tenant)
    end
  end

  @doc """
  Marks a claimed delivery failed, using the same token/lease gate as
  `mark_processed/4`. `permanent?` selects `:failed_permanent` over
  `:failed_retryable`.
  """
  @spec mark_failed(module(), term(), non_neg_integer(), String.t(), boolean(), keyword()) ::
          :ok | {:error, :stale_token | term()}
  def mark_failed(resource, delivery_id, token, error_class, permanent?, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      gated_update(
        resource,
        delivery_id,
        token,
        :mark_failed,
        %{error_class: error_class, permanent?: permanent?},
        tenant
      )
    end
  end

  @doc """
  Extends the caller's lease, gated on the caller's token under an
  unexpired lease.
  """
  @spec renew(module(), term(), non_neg_integer(), keyword()) ::
          :ok | {:error, :stale_token | term()}
  def renew(resource, delivery_id, token, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      gated_update(
        resource,
        delivery_id,
        token,
        :renew,
        %{
          lease_expires_at: DateTime.add(now(), lease_seconds(resource), :second)
        },
        tenant
      )
    end
  end

  @doc """
  Re-drives deliveries whose claims died with an expired lease (crash
  between claim and mark). Returns the number re-driven; unexpired leases
  and terminal rows are left alone. `:tenant` scopes the sweep; a
  tenant-less global reap over a multitenant ledger is the named
  `{:error, :tenant_required}` (the unscoped read would otherwise fail);
  per-tenant sweeps compose with `AshHooks.reap_all/2`.

  Rows that cannot be re-driven (inbound declaration removed, provider
  unresolved) are skipped without stopping the sweep. Handler and parser
  exceptions, exits, and throws are recorded as retryable failures and count as
  re-driven when that write succeeds. One failing row never stops the remaining
  rows.
  """
  @spec reap(module(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :tenant_required | :tenancy_mismatch}
  def reap(resource, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      now = now()

      expired =
        AshHooks.Contention.run(fn ->
          AshHooks.Phase.run(
            resource
            |> claim_alias_filter(nil)
            |> Ash.Query.filter(status == :claimed and lease_expires_at < ^now),
            tenant,
            &Ash.read(&1, authorize?: false, tenant: tenant)
          )
        end)
        |> case do
          {:ok, rows} -> rows
          {:error, error} -> raise error
        end

      re_driven =
        expired
        |> Enum.map(&safe_redrive(resource, &1, tenant))
        |> Enum.count(&match?({:ok, _}, &1))

      {:ok, re_driven}
    end
  end

  # Provider callbacks are contained in handling_outcome. The redrive also
  # runs the host's own code on the ledger (resource changes and hooks on
  # the claim and mark actions), which Ash re-raises; its raises, throws,
  # and exits fail only this row.
  defp safe_redrive(resource, row, tenant) do
    redrive(resource, row, tenant)
  rescue
    _reason -> {:error, :redrive_crashed}
  catch
    kind, _reason when kind in [:exit, :throw] -> {:error, :redrive_crashed}
  end

  # ────────────────────────── internals ──────────────────────────

  defp drive(_resource, %{decode_result: {:error, :malformed_payload}}, delivery, true),
    do: {:ok, :created, delivery}

  defp drive(resource, env, delivery, created?) do
    key = PrimaryKey.map(delivery)

    case claim_delivery(resource, key, tenant: env[:tenant]) do
      {:error, :lease_held} ->
        {:ok, result(created?), delivery}

      {:error, error} ->
        {:error, error}

      {:ok, _token, claimed} ->
        # The persisted row is the record of truth: a byte-differing
        # redelivery under the same identity drives the FIRST persisted
        # payload, never the new bytes.
        with {:ok, handling_env} <- row_env(resource, claimed, env[:tenant]),
             {:ok, final} <- handle_and_mark(resource, handling_env, key, claimed) do
          {:ok, result(created?), final}
        end
    end
  end

  defp handle_and_mark(resource, env, delivery_id, claimed) do
    tenant = env[:tenant]

    case handling_outcome(env) do
      :processed ->
        gated_update(resource, delivery_id, claimed.fencing_token, :mark_processed, %{}, tenant)

      {:failed, error_class, permanent?} ->
        gated_update(
          resource,
          delivery_id,
          claimed.fencing_token,
          :mark_failed,
          %{error_class: error_class, permanent?: permanent?},
          tenant
        )
    end
    |> case do
      :ok -> reload(resource, delivery_id, tenant)
      {:error, :stale_token} -> reload(resource, delivery_id, tenant)
      {:error, error} -> {:error, error}
    end
  end

  defp handling_outcome(env) do
    parsed_type =
      Provider.parse_event_type(env.provider, env.payload, %{
        env.context
        | delivery_id: nil,
          external_event_id: nil
      })

    handling_outcome(parsed_type, env)
  rescue
    _reason -> {:failed, "handler_crashed", false}
  catch
    kind, _reason when kind in [:exit, :throw] -> {:failed, "handler_crashed", false}
  end

  defp handling_outcome({:ok, type}, env) when is_atom(type) do
    case Provider.handle_event(env.provider, type, env.payload, env.context) do
      {:ok, _value} -> :processed
      {:error, :retry, term} -> {:failed, error_class_string(term), false}
      {:error, :permanent, term} -> {:failed, error_class_string(term), true}
      _ -> {:failed, "invalid_handler_result", false}
    end
  end

  defp handling_outcome({:error, reason}, _env)
       when reason in [:unknown_event_type, :malformed_payload],
       do: {:failed, Atom.to_string(reason), true}

  defp handling_outcome(_parsed_type, _env), do: {:failed, "invalid_handler_result", false}

  # The handling env for a claimed row is rebuilt from the PERSISTED row:
  # payload, digest, and type come from the ledger of record, so a
  # byte-differing redelivery under the same identity can never process
  # bytes the ledger does not show.
  defp row_env(resource, row, tenant) do
    with {:ok, inbound} <- fetch_inbound(resource, row.provider),
         {:ok, provider} <- receipt_provider(inbound, row) do
      scope =
        resource
        |> Extension.get_opt([:inbound_delivery], :scope_identity, [])
        |> Map.new(&{&1, Map.fetch!(row, &1)})

      key = PrimaryKey.map(row)

      delivery_id =
        case Map.values(key) do
          [value] -> value
          _ -> key
        end

      context = %DeliveryContext{
        tenant: Tenancy.from_row(row),
        source: row.provider,
        scope: scope,
        provider_alias: if(inbound.source_record, do: row.provider_alias),
        delivery_id: delivery_id,
        external_event_id: row.external_event_id,
        verified_facts: Map.get(row, :verified_facts)
      }

      {:ok,
       %{
         name: row.provider,
         provider: provider,
         payload: row.payload,
         digest: row.payload_digest,
         external_event_id: row.external_event_id,
         scope: scope,
         tenant: tenant,
         context: context
       }}
    end
  end

  defp receipt_provider(%{source_record: nil} = inbound, row),
    do: resolve_provider(inbound, row.provider)

  defp receipt_provider(inbound, row),
    do: source_provider(inbound.source_record, row.provider_alias)

  # Recovery needs only the receipt and the compile-time provider allowlist.
  defp redrive(resource, row, tenant) do
    key = PrimaryKey.map(row)

    with {:ok, _token, claimed} <- claim_delivery(resource, key, tenant: tenant),
         do: drive_claimed(resource, claimed, tenant)
  end

  defp drive_claimed(resource, claimed, tenant) do
    with {:ok, env} <- row_env(resource, claimed, tenant),
         do: handle_and_mark(resource, env, PrimaryKey.map(claimed), claimed)
  end

  defp record_provider_alias?(resource),
    do: Extension.get_opt(resource, [:inbound_delivery], :record_provider_alias, :off) == :on

  defp source_record_names(resource) do
    resource
    |> Extension.get_entities([:webhooks])
    |> Enum.filter(&(is_struct(&1, AshHooks.Inbound) and not is_nil(&1.source_record)))
    |> Enum.map(& &1.name)
  end

  defp claim_alias_filter(query, adoption_alias) do
    case adoption_alias do
      nil ->
        resource = Ash.Query.new(query).resource
        names = source_record_names(resource)

        if names == [],
          do: query,
          else: Ash.Query.filter(query, provider not in ^names or not is_nil(provider_alias))

      _alias ->
        Ash.Query.filter(query, is_nil(provider_alias))
    end
  end

  defp adoption_update(adoption_alias) do
    case adoption_alias do
      nil -> %{}
      alias -> %{provider_alias: alias}
    end
  end

  @doc false
  def adopt_provider_alias(source, name, alias, opts) do
    ledger = Storage.option(source, :ledger)
    limit = Keyword.get(opts, :limit, 100)

    with :ok <- Phase.outside_transaction(ledger),
         {:ok, tenant} <- Tenancy.resolve([ledger, source], opts[:tenant]),
         :ok <- adoption_target(source, ledger, name, alias, opts, limit),
         {:ok, rows} <- adoption_rows(ledger, name, tenant, limit) do
      result = Enum.reduce_while(rows, {:ok, 0}, &adopt_row(ledger, tenant, alias, &1, &2))

      with {:ok, driven} <- result,
           {:ok, remaining} <- adoption_remaining(ledger, name, tenant),
           do: {:ok, %{driven: driven, remaining: remaining}}
    end
  end

  defp adopt_row(ledger, tenant, alias, row, {:ok, count}) do
    case claim(ledger, PrimaryKey.map(row), [tenant: tenant], alias) do
      {:ok, _, claimed} ->
        _ = drive_claimed(ledger, claimed, tenant)
        {:cont, {:ok, count + 1}}

      {:error, :lease_held} ->
        {:cont, {:ok, count}}

      error ->
        {:halt, error}
    end
  end

  defp adoption_target(source, ledger, name, alias, opts, limit) do
    inbound = Info.inbound(ledger, name)
    providers = Storage.option(source, :providers)

    cond do
      not (is_integer(limit) and limit > 0) ->
        {:error, :invalid_limit}

      is_nil(inbound) or inbound.source_record != source ->
        {:error, :source_mismatch}

      not Keyword.has_key?(providers, alias) ->
        {:error, :provider_mismatch}

      opts[:expected_provider] && opts[:expected_provider] != providers[alias] ->
        {:error, :provider_mismatch}

      true ->
        :ok
    end
  end

  defp adoption_rows(ledger, name, tenant, limit) do
    at = now()

    Phase.run(
      ledger
      |> Ash.Query.filter(
        provider == ^name and is_nil(provider_alias) and
          (status in [:received, :failed_retryable] or
             (status == :claimed and lease_expires_at < ^at))
      )
      |> Ash.Query.limit(limit),
      tenant,
      &Ash.read(&1, authorize?: false, tenant: tenant)
    )
  end

  defp adoption_remaining(ledger, name, tenant) do
    Phase.run(
      ledger
      |> Ash.Query.filter(
        provider == ^name and is_nil(provider_alias) and
          status in [:received, :failed_retryable, :claimed]
      ),
      tenant,
      &Ash.count(&1, authorize?: false, tenant: tenant)
    )
  end

  defp reload(resource, delivery_id, tenant) do
    # the reload after a successful mark must not crash the caller for a
    # delivered-and-processed event under read contention (consumer journal
    # modes can block readers on writers)
    AshHooks.Contention.run(fn -> read_by_key(resource, delivery_id, tenant) end)
  end

  defp gated_update(resource, delivery_id, token, action, input, tenant) do
    with {:ok, key} <- normalize_primary_key(resource, delivery_id) do
      result =
        AshHooks.Contention.run(fn ->
          AshHooks.Phase.bulk(
            resource
            |> Ash.Query.do_filter(key)
            |> Ash.Query.filter(
              fencing_token == ^token and status == :claimed and lease_expires_at > ^now()
            ),
            tenant,
            &Ash.bulk_update(&1, action, input,
              authorize?: false,
              return_records?: true,
              return_errors?: true,
              strategy: [:atomic],
              tenant: tenant
            )
          )
        end)

      finalize_update(result, action)
    end
  end

  defp finalize_update(%Ash.BulkResult{status: :success, records: [row]}, action) do
    if action == :mark_failed, do: emit_failure(row)
    :ok
  end

  defp finalize_update(%Ash.BulkResult{status: :success, records: []}, _action),
    do: {:error, :stale_token}

  defp finalize_update(%Ash.BulkResult{errors: [error | _]}, _action), do: {:error, error}

  defp read_by_key(resource, key, tenant) do
    AshHooks.Phase.run(
      resource
      |> Ash.Query.do_filter(key),
      tenant,
      &Ash.read_one(&1, authorize?: false, tenant: tenant)
    )
    |> case do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  defp normalize_primary_key(resource, %resource{} = record),
    do: {:ok, PrimaryKey.map(record)}

  defp normalize_primary_key(resource, key) when is_map(key) do
    key
    |> PrimaryKey.encode()
    |> then(&PrimaryKey.decode(resource, &1))
  rescue
    ArgumentError -> {:error, :invalid_primary_key}
  end

  defp normalize_primary_key(resource, value) do
    case Ash.Resource.Info.primary_key(resource) do
      [name] -> PrimaryKey.decode(resource, %{Atom.to_string(name) => value})
      _composite -> {:error, :primary_key_mismatch}
    end
  end

  defp result(true), do: :created
  defp result(false), do: :duplicate

  # resolve/4: provider + inbound entity + secret + verification + decode +
  # digest + external id + parsed type. Nothing here writes to the ledger.
  # A signature-valid but undecodable body persists as `%{}` for providers
  # without a stable-identity callback and is recorded permanently malformed
  # when inserted, without a claim. The decode verdict stays separate from
  # the parsed event type so the placeholder cannot erase it. A provider
  # identity callback may reject that decoded
  # shape explicitly; ingress never substitutes the raw digest after a
  # callback error.
  defp resolve(resource, name, raw_body, ctx) do
    {module, function, args} =
      Extension.get_opt(resource, [:inbound_delivery], :json_decoder, {Jason, :decode, []})

    decoder = fn bytes ->
      Provider.decode_json(bytes, fn input -> apply(module, function, [input | args]) end)
    end

    ctx = Map.put(ctx, :json_decoder, decoder)

    with {:ok, inbound} <- fetch_inbound(resource, name),
         {:ok, resolved} <- request_source(resource, name, ctx),
         :ok <- resolved_pause(resolved),
         :ok <- check_replay_window(inbound, resolved.provider, name),
         :ok <- check_raw_body(raw_body, name),
         {:ok, resolved, facts} <- verify_resolved(resolved, raw_body, ctx, inbound) do
      digest = content_digest(raw_body)

      context = %DeliveryContext{
        tenant: ctx[:tenant],
        source: name,
        scope: resolved.scope,
        provider_alias: resolved.provider_alias
      }

      {payload, parsed_type, decode_result} =
        decode_and_parse(resolved.provider, raw_body, inbound.body_format, decoder, context)

      with {:ok, external_event_id} <-
             external_event_id(inbound, resolved.provider, payload, digest, name, context) do
        {:ok,
         %{
           name: name,
           provider: resolved.provider,
           provider_alias: resolved.provider_alias,
           verified_facts: facts,
           inbound: inbound,
           payload: payload,
           digest: digest,
           external_event_id: external_event_id,
           parsed_type: parsed_type,
           decode_result: decode_result,
           type_string: type_string(parsed_type),
           scope: resolved.scope,
           tenant: ctx[:tenant]
         }}
      end
    end
  end

  @doc """
  Resolves one inbound declaration, casting and constraining scope before a
  source lookup. A source row is read in a tenant phase; an absent row returns
  `UnknownSource`. Declarations without `source_record` perform no source read.
  Options: `:tenant`, `:scope`. The returned struct can be passed as
  `:resolved_source` to ingest, as the HTTP entry point does.
  """
  @spec resolve_source(module(), atom(), keyword()) ::
          {:ok, AshHooks.Inbound.ResolvedSource.t()} | {:error, term()}
  def resolve_source(resource, name, opts \\ []) do
    with {:ok, inbound} <- fetch_inbound(resource, name),
         {:ok, scope} <- cast_scope(resource, opts[:scope]),
         {:ok, tenant} <-
           Tenancy.resolve(
             Enum.reject([resource, inbound.source_record], &is_nil/1),
             opts[:tenant]
           ) do
      resolve_declaration(resource, inbound, scope, tenant)
    end
  end

  defp resolve_declaration(resource, %{source_record: source} = inbound, scope, tenant)
       when not is_nil(source),
       do: source_from_row(resource, inbound, scope, tenant)

  defp resolve_declaration(_resource, inbound, scope, tenant) do
    with {:ok, provider} <- resolve_provider(inbound, inbound.name) do
      {:ok,
       %ResolvedSource{
         name: inbound.name,
         provider: provider,
         scope: scope,
         paused?: check_paused(inbound, inbound.name, tenant) != :ok
       }}
    end
  end

  defp request_source(_resource, name, %{resolved_source: %ResolvedSource{name: name} = source}),
    do: {:ok, source}

  defp request_source(resource, name, ctx), do: resolve_source(resource, name, Map.to_list(ctx))
  defp resolved_pause(%ResolvedSource{paused?: true}), do: {:error, :source_paused}
  defp resolved_pause(_), do: :ok

  defp source_from_row(ledger, inbound, scope, tenant) do
    source = inbound.source_record
    source_attribute = Storage.option(source, :source_attribute, :source)

    Phase.run([ledger, source], tenant, fn ->
      query =
        source
        |> Storage.owner_query(tenant)
        |> Ash.Query.do_filter(scope)
        |> Ash.Query.do_filter(%{source_attribute => inbound.name})

      with {:ok, row} <- Ash.read_one(query, authorize?: false, tenant: tenant),
           do: resolved_row(inbound, row, scope)
    end)
  end

  defp resolved_row(_inbound, nil, _scope),
    do: {:error, UnknownSource.exception([])}

  defp resolved_row(inbound, row, scope) do
    tenant = Tenancy.from_row(row)

    with {:ok, provider} <- source_provider(inbound.source_record, row.provider),
         {:ok, canonical} <-
           Custody.canonical_tenant(
             tenant,
             row.__struct__,
             Custody.tenant_options(row.__struct__)
           ) do
      keys =
        for {field, kind} <- source_slots(row),
            ref = Map.get(row, field),
            not is_nil(ref),
            do: %Custody.Key{
              ref: ref,
              kind: Map.get(row, kind),
              tenant: canonical,
              custodian: Storage.custodian(row.__struct__)
            }

      {:ok,
       %ResolvedSource{
         name: inbound.name,
         provider_alias: row.provider,
         provider: provider,
         scope: scope,
         paused?: row.paused,
         keys: keys,
         public_key:
           if(row.public_key,
             do: %Custody.PublicKey{kind: row.public_key_kind, key: row.public_key}
           ),
         record: row
       }}
    end
  end

  defp source_slots(row) do
    previous = row.previous_secret_retired_at

    if previous && DateTime.compare(previous, DateTime.utc_now()) == :gt,
      do: [{:secret_ref, :secret_kind}, {:previous_secret_ref, :previous_secret_kind}],
      else: [{:secret_ref, :secret_kind}]
  end

  defp source_provider(source, alias) do
    case Keyword.fetch(Storage.option(source, :providers), alias) do
      {:ok, provider} ->
        resolve_provider(%{provider: provider}, nil)

      :error ->
        {:error, UnknownError.exception(error: "source provider alias is outside its allowlist")}
    end
  end

  defp verify_resolved(source, body, ctx, inbound) do
    case verify_source_keys(source, body, ctx, inbound) do
      {:error, %AshHooks.Errors.Invalid.UnknownKey{ref: ref} = reason}
      when not is_nil(source.record) and is_binary(ref) ->
        refresh_source_keys(source, body, ctx, inbound, reason)

      {:ok, facts} ->
        {:ok, source, facts}

      error ->
        error
    end
  end

  defp refresh_source_keys(source, body, ctx, inbound, reason) do
    ledger = Storage.option(source.record.__struct__, :ledger)

    with {:ok, fresh} <-
           resolve_source(ledger, source.name, tenant: ctx[:tenant], scope: source.scope),
         false <- Enum.any?(fresh.keys, &(&1.ref == reason.ref)) do
      with :ok <- resolved_pause(fresh),
           :ok <- check_replay_window(inbound, fresh.provider, source.name),
           {:ok, facts} <- verify_source_keys(fresh, body, ctx, inbound),
           do: {:ok, fresh, facts}
    else
      true -> {:error, reason}
      error -> error
    end
  end

  defp verify_source_keys(%ResolvedSource{record: nil} = source, body, ctx, inbound) do
    with {:ok, secret} <- resolve_secret(source.provider, inbound, source.name, ctx),
         do: verify(source.provider, body, ctx, inbound, secret, source.name)
  end

  defp verify_source_keys(%ResolvedSource{keys: []} = source, body, ctx, inbound) do
    if source.public_key,
      do:
        verify(
          source.provider,
          body,
          ctx,
          %{inbound | previous_secret: nil},
          source.public_key,
          source.name
        ),
      else: secret_error(source.name)
  end

  defp verify_source_keys(source, body, ctx, inbound) do
    Enum.reduce_while(source.keys, {:error, nil}, fn key, {:error, failure} ->
      case verify(source.provider, body, ctx, %{inbound | previous_secret: nil}, key, source.name) do
        {:ok, facts} ->
          result =
            with :ok <- stamp_source_used(source.record, key.ref, ctx[:tenant]), do: {:ok, facts}

          {:halt, result}

        {:error, %UnknownError{}} = error ->
          {:halt, error}

        {:error, reason} ->
          {:cont, {:error, source_key_failure(failure, reason, source.name)}}
      end
    end)
  end

  defp source_key_failure(nil, reason, _name), do: reason

  defp source_key_failure(failure, reason, name),
    do: overlap_failure(failure, {:error, reason}, name)

  defp stamp_source_used(row, ref, tenant) do
    {field, stamp, action} =
      if row.secret_ref == ref,
        do: {:secret_ref, :secret_first_used_at, :mark_current_secret_used},
        else: {:previous_secret_ref, :previous_secret_first_used_at, :mark_previous_secret_used}

    if Map.get(row, stamp) do
      :ok
    else
      query =
        row.__struct__
        |> Storage.owner_query(tenant)
        |> Ash.Query.do_filter(PrimaryKey.filter(row))
        |> Ash.Query.do_filter(%{field => ref, stamp => [is_nil: true]})

      case Phase.bulk(
             query,
             tenant,
             &Ash.bulk_update(&1, action, %{used_at: DateTime.utc_now()},
               authorize?: false,
               tenant: tenant,
               strategy: [:atomic],
               return_errors?: true
             )
           ) do
        %Ash.BulkResult{status: :success} -> :ok
        %Ash.BulkResult{errors: [error | _]} -> {:error, error}
      end
    end
  end

  # The pause switch: while the declared source resolves true, every
  # request is refused BEFORE verification, persistence, or handling;
  # A 5xx response asks the sender to retry; recovery depends on its retry policy.
  defp check_paused(inbound, _name, tenant) do
    if inbound.paused && resolve_paused(inbound.paused, tenant) == true do
      {:error, :source_paused}
    else
      :ok
    end
  end

  defp resolve_paused({m, f, a}, _tenant), do: apply(m, f, a)

  defp resolve_paused({:app_env, [app | keys]}, _tenant),
    do: keys |> env_walk(Application.get_all_env(app)) |> truthy()

  defp resolve_paused(fun, _tenant) when is_function(fun, 0), do: truthy(fun.())

  defp resolve_paused(fun, tenant) when is_function(fun, 1) and not is_nil(tenant),
    do: truthy(fun.(tenant))

  defp resolve_paused(_other, _tenant), do: false

  defp truthy(true), do: true
  defp truthy(_other), do: false

  # Batch senders deliver top-level JSON ARRAYS; providers that
  # only accept maps fail lists closed through their own catch-all clauses
  # ({:error, :malformed_payload}); the shape decision belongs to the
  # provider, not the pipeline.
  defp decode_and_parse(provider, raw_body, format, decoder, context) do
    case Provider.decode_payload(provider, raw_body, format, decoder) do
      {:ok, payload} when is_map(payload) or is_list(payload) ->
        {payload, Provider.parse_event_type(provider, payload, context), :ok}

      {:ok, _scalar} ->
        {%{}, {:error, :malformed_payload}, {:error, :malformed_payload}}

      {:error, _} ->
        {%{}, {:error, :malformed_payload}, {:error, :malformed_payload}}
    end
  end

  defp fetch_inbound(resource, name) do
    case Info.inbound(resource, name) do
      nil ->
        {:error,
         UnknownError.exception(
           error:
             "no inbound #{inspect(name)} declaration on #{inspect(resource)}; add one under `webhooks`"
         )}

      inbound ->
        {:ok, inbound}
    end
  end

  defp resolve_provider(inbound, _name) do
    candidate = inbound.provider

    if Code.ensure_loaded?(candidate) and function_exported?(candidate, :verify_signature, 3) do
      {:ok, candidate}
    else
      {:error,
       UnknownError.exception(
         error:
           "provider #{inspect(candidate)} does not exist or does not implement " <>
             "AshHooks.Provider; set the `provider` option on the inbound declaration"
       )}
    end
  end

  # Runtime backstop for the compile-time verifier: a window on a
  # timestamp-less scheme silently verifies replays forever; reject before
  # anything runs. The verifier cannot see providers that were not loadable
  # at compile time; this check always can.
  defp check_replay_window(%{replay_window_seconds: nil}, _provider, _name), do: :ok

  defp check_replay_window(%{replay_window_seconds: window}, provider, name) do
    if Provider.timestamp_header(provider) do
      :ok
    else
      {:error,
       UnknownError.exception(
         error:
           "inbound #{inspect(name)} declares replay_window_seconds=#{window} but " <>
             "#{inspect(provider)} declares no timestamp header " <>
             "(AshHooks.Provider.timestamp_header/1 is nil); remove the window or implement the callback"
       )}
    end
  end

  defp resolve_secret(provider, inbound, name, ctx) do
    if Provider.secret_scope(provider) == :per_connection do
      # the tenant rides the per-connection resolution: an overriding
      # webhook_signing_secret/2 resolves per-tenant custody; a /1-only
      # provider ignores it and compiles unchanged
      case Provider.webhook_signing_secret(provider, ctx[:connection], ctx[:tenant]) do
        {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
        _else -> secret_error(name)
      end
    else
      resolve_secret_source(inbound.secret, name, ctx[:tenant])
    end
  end

  defp resolve_secret_source({m, f, a}, name, _tenant) do
    case apply(m, f, a) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _else -> secret_error(name)
    end
  end

  defp resolve_secret_source({:app_env, [app | rest]}, name, _tenant) do
    value = get_in(Application.get_all_env(app), rest)

    case value do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _else -> secret_error(name)
    end
  end

  # the 0-arity source is app-global; the 1-arity source resolves the
  # TENANT's secret (arity dispatch on literal fns is unambiguous)
  defp resolve_secret_source(fun, name, _tenant) when is_function(fun, 0) do
    case fun.() do
      {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _else -> secret_error(name)
    end
  end

  defp resolve_secret_source(fun, name, tenant) when is_function(fun, 1) do
    case fun.(tenant) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _else -> secret_error(name)
    end
  end

  defp secret_error(name), do: {:error, NoWebhookSecret.exception(provider: name)}

  defp check_raw_body(raw_body, _name) when is_binary(raw_body), do: :ok

  defp check_raw_body(_missing, name),
    do: {:error, MalformedPayload.exception(provider: name, detail: "no raw body")}

  # A missing/malformed signature header is attacker-controlled input: it
  # must fail closed as a tuple, never reach a provider guard as a crash
  # (default_verify_signature/4 would FunctionClauseError on non-binary).
  defp verify(provider, raw_body, ctx, inbound, secret, name) do
    source = Provider.signature_source(provider)

    if is_binary(ctx[:signature]) or source in [:body, :request] do
      ctx =
        if source == :body and not is_binary(ctx[:signature]),
          do: Map.put(ctx, :signature, raw_body),
          else: ctx

      verify_request(provider, raw_body, ctx, inbound, secret, name)
    else
      {:error, Errors.from_reason(:invalid_signature, provider: name)}
    end
  end

  defp verify_request(provider, raw_body, ctx, inbound, secret, name) do
    case request_headers(ctx[:headers]) do
      {:ok, headers, header_list} ->
        verify_ctx =
          %{
            signature: ctx[:signature],
            headers: headers,
            header_list: header_list,
            method: ctx[:method],
            request_uri: ctx[:request_uri],
            tenant: ctx[:tenant],
            host_context: ctx[:host_context],
            json_decoder: ctx.json_decoder
          }
          |> maybe_put_replay_window(inbound)

        case provider_verdict(provider, raw_body, verify_ctx, secret, name) do
          {:ok, facts} ->
            {:ok, facts}

          {:error, %UnknownError{}} = error ->
            error

          {:error, reason} ->
            verify_with_previous(provider, raw_body, verify_ctx, inbound, reason, name)
        end

      :error ->
        {:error, Errors.from_reason(:invalid_signature, provider: name)}
    end
  end

  # Provider callbacks own admission. Opaque host context is never retained in errors.
  defp provider_verdict(provider, body, context, key, name) do
    case provider.verify_signature(body, context, key) do
      :ok -> {:ok, nil}

      {:ok, facts} ->
        if AshHooks.Provider.VerifiedFacts.valid?(facts),
          do: {:ok, facts},
          else: {:error, Errors.from_reason(:unknown_error, provider: name)}

      {:error, reason} -> {:error, reason}
      _ -> {:error, Errors.from_reason(:unknown_error, provider: name)}
    end
  rescue
    _ -> {:error, Errors.from_reason(:unknown_error, provider: name)}
  catch
    _, _ -> {:error, Errors.from_reason(:unknown_error, provider: name)}
  end

  # A host map passes through unchanged, as in 2.x (its own construction
  # decided how repeated lines were kept); `header_list` carries its binary
  # entries only. An ordered list keeps every line for
  # `header_list` and joins repeated names with ", " (RFC 9110 field-line
  # combination) for the map. Anything else is not a header set: fail closed.
  defp request_headers(nil), do: {:ok, %{}, []}

  defp request_headers(headers) when is_map(headers) do
    lines =
      for {name, value} when is_binary(name) and is_binary(value) <- headers, do: {name, value}

    {:ok, headers, lines}
  end

  defp request_headers(headers) when is_list(headers) do
    with {:ok, lines} <- header_lines(headers, []) do
      map =
        lines
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {name, values} -> {name, Enum.join(values, ", ")} end)

      {:ok, map, lines}
    end
  end

  defp request_headers(_headers), do: :error

  defp header_lines([], lines), do: {:ok, Enum.reverse(lines)}

  defp header_lines([{name, value} | rest], lines) when is_binary(name) and is_binary(value),
    do: header_lines(rest, [{String.downcase(name, :ascii), value} | lines])

  defp header_lines(_headers, _lines), do: :error

  # The rotation overlap: when the declaration carries a previous_secret
  # source, a failing current-key verification retries the rotated-out key
  # so both keys verify until the option is removed (the window's end).
  # When both fail, the current key's failure is the answer unless it is an
  # invalid signature and the previous key could not be checked at all (an
  # unavailable, unknown or wrong-kind key, or an unrecognized failure):
  # then the previous key's failure is reported, as
  # `AshHooks.Provider.Signature.verification_result/1` ranks a key list, so
  # a request signed with the previous key is never answered as forged.
  defp verify_with_previous(
         _provider,
         _raw_body,
         _verify_ctx,
         %{previous_secret: nil},
         reason,
         name
       ) do
    {:error, Errors.from_reason(reason, provider: name)}
  end

  defp verify_with_previous(provider, raw_body, verify_ctx, inbound, reason, name) do
    case resolve_previous_secret(inbound, %{tenant: verify_ctx[:tenant]}) do
      {:ok, previous} ->
        case provider_verdict(provider, raw_body, verify_ctx, previous, name) do
          {:ok, facts} -> {:ok, facts}
          {:error, %UnknownError{}} = error -> error
          previous_result -> {:error, overlap_failure(reason, previous_result, name)}
        end

      _no_previous ->
        {:error, Errors.from_reason(reason, provider: name)}
    end
  end

  defp overlap_failure(reason, previous_result, name) do
    current = Errors.from_reason(reason, provider: name)

    previous =
      case previous_result do
        {:error, previous_reason} -> Errors.from_reason(previous_reason, provider: name)
        _unknown -> Errors.from_reason(:unknown_error, provider: name)
      end

    if is_struct(current, InvalidSignature) and not is_struct(previous, InvalidSignature),
      do: previous,
      else: current
  end

  defp resolve_previous_secret(%{previous_secret: source}, ctx) do
    tenant = ctx[:tenant]

    case source do
      {m, f, a} ->
        apply(m, f, a) |> as_secret()

      {:app_env, [app | keys]} ->
        value = env_walk(keys, Application.get_all_env(app))
        as_secret(if is_binary(value), do: {:ok, value}, else: value)

      fun when is_function(fun, 0) ->
        fun.() |> as_secret()

      fun when is_function(fun, 1) and not is_nil(tenant) ->
        fun.(tenant) |> as_secret()

      _ ->
        {:error, :no_webhook_secret}
    end
  end

  defp as_secret({:ok, secret}) when is_binary(secret) and secret != "", do: {:ok, secret}
  defp as_secret(_), do: {:error, :no_webhook_secret}

  # an app_env walk that steps off the tree (a missing intermediate key)
  # resolves nothing, never a crash on operator config
  defp env_walk(_keys, nil), do: nil
  defp env_walk([], acc), do: acc
  defp env_walk([key | rest], acc) when is_list(acc), do: env_walk(rest, Keyword.get(acc, key))
  defp env_walk(_keys, _not_a_keyword), do: nil

  defp maybe_put_replay_window(verify_ctx, %{replay_window_seconds: nil}), do: verify_ctx

  defp maybe_put_replay_window(verify_ctx, %{replay_window_seconds: window}),
    do: Map.put(verify_ctx, :replay_window_seconds, window)

  # Scope carries values for the DECLARED slots and nothing else: keys are
  # taken by allowlist, so caller scope data can never overwrite the
  # verified ledger identity fields, and unknown keys
  # are rejected rather than silently shaping the ingest input.
  defp cast_scope(resource, supplied) do
    scope = Map.new(supplied || %{})
    declared = Extension.get_opt(resource, [:inbound_delivery], :scope_identity, [])
    known = Enum.flat_map(declared, &[&1, Atom.to_string(&1)])

    if Enum.any?(Map.keys(scope), &(&1 not in known)) do
      {:error,
       MalformedPayload.exception(
         detail: "unknown scope keys: scope carries only declared scope_identity slots"
       )}
    else
      Enum.reduce_while(declared, {:ok, %{}}, &cast_scope_value(resource, scope, &1, &2))
    end
  end

  defp cast_scope_value(resource, scope, name, {:ok, values}) do
    value = Map.get(scope, name, Map.get(scope, Atom.to_string(name)))
    attribute = Ash.Resource.Info.attribute(resource, name)

    with false <- is_nil(value),
         {:ok, cast} <- Ash.Type.cast_input(attribute.type, value, attribute.constraints),
         {:ok, cast} <- Ash.Type.apply_constraints(attribute.type, cast, attribute.constraints),
         false <- is_nil(cast) do
      {:cont, {:ok, Map.put(values, name, cast)}}
    else
      _ ->
        {:halt,
         {:error,
          MalformedPayload.exception(
            detail: "missing or invalid scope value for #{inspect(name)}"
          )}}
    end
  end

  defp content_digest(raw_body),
    do: :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)

  defp external_event_id(%{event_id: extractor}, _provider, payload, digest, _name, _context)
       when is_function(extractor, 1) do
    id =
      case extractor.(payload) do
        # Preserve the established host-extractor contract: invalid results
        # use the raw digest, and overlong strings hash to the bounded column.
        {:ok, id} when is_binary(id) and byte_size(id) <= 255 -> id
        {:ok, id} when is_binary(id) -> content_digest(id)
        _else -> digest
      end

    {:ok, id}
  end

  defp external_event_id(_inbound, provider, payload, digest, name, context) do
    case Provider.event_identity(provider, payload, context) do
      :not_supported ->
        {:ok, digest}

      {:ok, id} when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 255 ->
        {:ok, id}

      _invalid_result ->
        provider_identity_error(name)
    end
  end

  defp provider_identity_error(name) do
    {:error,
     MalformedPayload.exception(
       provider: name,
       detail: "provider event identity callback rejected the decoded payload"
     )}
  end

  defp type_string({:ok, type}) when is_atom(type), do: Atom.to_string(type)
  defp type_string(_), do: nil

  # error_class is a bounded classification field, never an arbitrary dump:
  # binaries truncate, atoms name themselves, and structures (which can carry
  # payloads or secrets) classify without their contents. The attribute itself carries no max_length; the cap bounds
  # what reaches the TEXT column in any counting mode. Invalid UTF-8
  # collapses to the [binary] placeholder (the redaction floor's convention):
  # the :string write would reject invalid bytes and the failure would never
  # be recorded, leaving the delivery re-drivable.
  defp error_class_string(term) when is_binary(term) do
    if String.valid?(term), do: AshHooks.BoundedText.cap(term, 255), else: "[binary]"
  end

  defp error_class_string(term) when is_atom(term), do: Atom.to_string(term)
  defp error_class_string(_term), do: "unclassified"

  # Second-truncated UTC: sqlite stores TEXT ISO8601 and compares lexically;
  # uniform (fraction-less) precision keeps lexical == chronological.
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp lease_seconds(resource) do
    Extension.get_opt(
      resource,
      [:inbound_delivery],
      :lease_seconds,
      @lease_default_seconds
    )
  end
end
