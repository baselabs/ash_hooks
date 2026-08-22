defmodule AshHooks.Ingress do
  @moduledoc """
  The inbound pipeline driver: verify → ingest → claim → handle → mark,
  over a ledger resource carrying the `AshHooks.InboundDelivery` extension.

  `ingest/4` is the sync-mode entry point a consumer's controller calls with
  the raw request body (captured pre-parser via the endpoint body_reader — a
  router plug cannot recover pre-parse bytes). The machine's crash-safety
  contract:

    * the raw payload persists BEFORE any handling (audit + verification
      integrity via `payload_digest`);
    * the unique identity + storage-level uniqueness make exactly one
      `:created` per delivery — concurrent or sequential duplicates get
      `:duplicate`;
    * a claim is a WHERE-gated update (`status == :received`, a
      re-driveable failure, or an EXPIRED lease) that bumps the monotonic
      fencing token — so a redelivery of a stranded row re-drives it, never
      no-ops (the incumbent's silent-loss window);
    * marks are gated on the caller's token AND an unexpired lease — a
      stale owner (superseded or expired) is rejected.

  Returns `{:ok, :created | :duplicate, delivery}` — the delivery's
  `status` carries the outcome (`:processed`, `:failed_retryable`,
  `:failed_permanent`); handler failures are recorded in the ledger, not
  raised. Verification/config failures return `{:error, error}` BEFORE any
  ledger write (fail closed: missing secret verifies nothing; a missing raw
  body never runs).

  The individual machine steps (`ingest_delivery/2`, `claim_delivery/2`,
  `mark_processed/3`, `mark_failed/5`, `renew/3`, `reap/1`) are public for
  composition and monitoring — a consumer-driven async pipeline (your own
  202-then-claim flow) and the reaper drive the same steps.

  All ledger operations run unauthorized: the signature verification IS the
  trust boundary for writes. The package injects NO read policies — read
  access to the ledger resource is governed ENTIRELY by the consumer's own
  domain policies. The ledger stores raw provider payloads: mount it behind
  policies that deny reads by default (see README → Security).
  """

  require Ash.Query

  alias AshHooks.Errors
  alias AshHooks.Errors.Invalid.MalformedPayload
  alias AshHooks.Errors.Invalid.NoWebhookSecret
  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.Info
  alias AshHooks.Provider
  alias Spark.Dsl.Extension

  @typedoc """
  The request context. `:signature` is the provider's signature header
  value; `:headers` the lowercased request headers; `:scope` carries values
  for the ledger's declared `scope_identity` slots; `:connection` is the
  per-connection provider's secret source argument.
  """
  @type ctx :: %{
          optional(:signature) => String.t(),
          optional(:headers) => %{optional(String.t()) => String.t()},
          optional(:method) => String.t() | nil,
          optional(:request_uri) => String.t() | nil,
          optional(:connection) => term(),
          optional(:scope) => %{optional(atom() | String.t()) => term()}
        }

  @lease_default_seconds 30

  # Transient sqlite write-lock contention (pool > 1 consumers on the
  # best-effort sqlite leg): the fenced ops are idempotent or gate-reevaluated,
  # so a bounded wall-clock retry converts busy/locked errors into convergence
  # instead of surfacing them to the caller. Classified NARROWLY by exqlite's
  # busy/locked error text — no other data layer's errors can match, so e.g.
  # postgres consumers see zero behavior change.
  @transient_retry_deadline_ms 2_000
  @transient_retry_spacing_ms 100
  @transient_retry_jitter_ms 50

  # ────────────────────────── sync pipeline ──────────────────────────

  @doc """
  Drives one inbound delivery through the full sync pipeline.
  """
  @spec ingest(module(), atom(), binary() | nil, ctx()) ::
          {:ok, :created | :duplicate, struct()} | {:error, term()}
  def ingest(resource, name, raw_body, ctx) do
    started = System.monotonic_time()

    with {:ok, env} <- verify(resource, name, raw_body, ctx, started),
         {:ok, created?, delivery} <- ingest_delivery(resource, env) do
      drive(resource, env, delivery, created?)
    end
  end

  # the verify event wraps resolution + signature verification; the
  # reason is the FIXED error class atom, never the raw error payload
  # (ADR-0005's telemetry floor)
  defp verify(resource, name, raw_body, ctx, started) do
    case resolve(resource, name, raw_body, ctx) do
      {:ok, _env} = ok ->
        emit_verify(name, :ok, nil, started)
        ok

      {:error, reason} ->
        emit_verify(name, :invalid, error_class(reason), started)
        {:error, reason}
    end
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

  defp error_class(%{__exception__: true} = error) do
    case error.__struct__ |> Module.split() do
      ["AshHooks", "Errors", "Invalid", class] ->
        Macro.underscore(class) |> String.to_atom()

      _other_namespace ->
        nil
    end
  end

  defp error_class(_non_exception), do: nil

  @doc """
  Persists the ledger row (raw payload BEFORE handling) via the
  no-touch unique upsert. Classifies `:created` by comparing the surviving
  row's client-generated id against ours.
  """
  @spec ingest_delivery(module(), map()) :: {:ok, boolean(), struct()} | {:error, term()}
  def ingest_delivery(resource, env) do
    id = Ash.UUID.generate()

    input =
      %{
        id: id,
        provider: env.name,
        external_event_id: env.external_event_id,
        external_event_type: env.type_string,
        payload: env.payload,
        payload_digest: env.digest
      }
      |> Map.merge(env.scope)

    with_transient_retry(fn ->
      case Ash.create(resource, input, action: :ingest, authorize?: false) do
        {:ok, delivery} ->
          created? = delivery.id == id

          :telemetry.execute(
            [:ash_hooks, :ingress, :dedup],
            %{},
            %{source: env.name, outcome: if(created?, do: :created, else: :duplicate)}
          )

          {:ok, created?, delivery}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  @doc """
  Claims a delivery: WHERE-gated on `status == :received`, a re-driveable
  failure, or an EXPIRED lease — bumps the fencing token atomically and
  takes a fresh lease. A live foreign lease (or a terminal row) returns
  `{:error, :lease_held}`.
  """
  @spec claim_delivery(module(), term()) ::
          {:ok, non_neg_integer(), struct()} | {:error, :lease_held | term()}
  def claim_delivery(resource, delivery_id) do
    # `now` and the lease are recomputed on EVERY attempt: a retry that
    # spends contention time sleeping must not grant a lease that is
    # shorter than configured — or already expired (cross-vendor finding).
    result =
      with_transient_retry(fn ->
        attempt_now = now()
        lease_expires_at = DateTime.add(attempt_now, lease_seconds(resource), :second)

        resource
        |> Ash.Query.filter(
          id == ^delivery_id and
            (status == :received or status == :failed_retryable or
               (status == :claimed and lease_expires_at < ^attempt_now))
        )
        |> Ash.bulk_update(:claim, %{lease_expires_at: lease_expires_at},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic]
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

      %Ash.BulkResult{} ->
        {:error, :claim_failed}
    end
  end

  @doc """
  Retention hook: deletes TERMINAL ledger rows (`:processed`,
  `:failed_permanent`) older than `older_than`, by the resource's
  `inserted_at` (add Ash `timestamps()` to the resource and its
  migration). Non-terminal rows are never deleted — retryable and
  lease-held deliveries keep their dedup identity and re-drive path.

  Deleting a terminal row re-opens its dedup identity: a replayed
  delivery of the same webhook processes again (inbound), and — on the
  outbound side — a re-emission of the same event re-dispatches and
  double-sends. Set the TTL beyond any replay/re-emission horizon.
  Returns `{:ok, deleted_count}`.
  """
  @spec prune(module(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(resource, opts) do
    older_than = normalize_cutoff(Keyword.fetch!(opts, :older_than))

    with :ok <- require_timestamps!(resource) do
      require Ash.Query

      result =
        with_transient_retry(fn ->
          resource
          |> Ash.Query.filter(
            status in [:processed, :failed_permanent] and inserted_at < ^older_than
          )
          |> Ash.bulk_destroy(:prune, %{},
            authorize?: false,
            return_records?: true,
            return_errors?: true,
            strategy: [:atomic]
          )
        end)

      case result do
        %Ash.BulkResult{status: :success, records: rows} -> {:ok, length(rows)}
        %Ash.BulkResult{errors: [error | _]} -> {:error, error}
        %Ash.BulkResult{} -> {:error, :prune_failed}
      end
    end
  end

  @doc """
  Retention field-redaction hook: replaces the stored payload of a
  CLAIMED delivery with `redactor.(payload)` — under the caller's token
  and an unexpired lease (the `mark_processed/3` fence). The row keeps
  its dedup identity; only the payload changes. `payload_digest` is
  deliberately NOT updated (it binds the ORIGINAL signed bytes — the
  audit trail).

  The redactor (`{m, f}` | 1-arity fun) receives the stored payload
  (map or list — HubSpot batches are lists) and returns the
  replacement (same type) or nil to leave it unchanged. A crashing or
  invalid redactor returns an error and leaves the payload UNCHANGED
  (fail-safe for the audit record — the caller may retry). Redact,
  then mark promptly: a lease expiry between redact and mark re-drives
  the row with the redacted payload.
  """
  @spec redact_payload(module(), term(), non_neg_integer(), term()) ::
          :ok | {:error, :stale_token | :redactor_crash | :invalid_redactor_result | term()}
  def redact_payload(resource, delivery_id, token, redactor) do
    case Ash.get(resource, delivery_id, authorize?: false) do
      {:ok, delivery} ->
        # the fence is checked BEFORE the redactor sees the payload — a
        # stale token must not receive sensitive bytes through the
        # callback even though the eventual write would be rejected
        # (cross-vendor finding)
        if fence_valid?(delivery, token) do
          apply_redactor(redactor, delivery.payload, resource, delivery_id, token)
        else
          {:error, :stale_token}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fence_valid?(delivery, token) do
    delivery.fencing_token == token and delivery.status == :claimed and
      DateTime.compare(delivery.lease_expires_at, now()) == :gt
  end

  defp apply_redactor(redactor, payload, resource, delivery_id, token) do
    case redactor_fun(redactor).(payload) do
      nil ->
        :ok

      new_payload when is_map(new_payload) or is_list(new_payload) ->
        gated_update(resource, delivery_id, token, :redact_payload, %{payload: new_payload})

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

  # sqlite stores timestamps as ISO8601 TEXT compared LEXICALLY — a
  # second-truncated cutoff would sort AFTER same-second usec rows and
  # delete them early. Normalizing to microsecond precision keeps the
  # lexical and chronological orders identical (adversarial finding).
  defp normalize_cutoff(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp require_timestamps!(resource) do
    if Ash.Resource.Info.attribute(resource, :inserted_at) do
      :ok
    else
      {:error,
       AshHooks.Errors.Unknown.UnknownError.exception(
         error:
           inspect(resource) <>
             " has no :inserted_at — add `timestamps()` to its attributes " <>
             "(and the inserted_at/updated_at columns to its migration) to use the retention hooks"
       )}
    end
  end

  @doc """
  Marks a claimed delivery processed — gated on the caller's token under an
  unexpired lease.
  """
  @spec mark_processed(module(), term(), non_neg_integer()) ::
          :ok | {:error, :stale_token | term()}
  def mark_processed(resource, delivery_id, token) do
    gated_update(resource, delivery_id, token, :mark_processed, %{})
  end

  @doc """
  Marks a claimed delivery failed — same token/lease gate as
  `mark_processed/3`. `permanent?` selects `:failed_permanent` over
  `:failed_retryable`.
  """
  @spec mark_failed(module(), term(), non_neg_integer(), String.t(), boolean()) ::
          :ok | {:error, :stale_token | term()}
  def mark_failed(resource, delivery_id, token, error_class, permanent?) do
    gated_update(resource, delivery_id, token, :mark_failed, %{
      error_class: error_class,
      permanent?: permanent?
    })
  end

  @doc """
  Extends the caller's lease — gated on the caller's token under an
  unexpired lease.
  """
  @spec renew(module(), term(), non_neg_integer()) :: :ok | {:error, :stale_token | term()}
  def renew(resource, delivery_id, token) do
    gated_update(resource, delivery_id, token, :renew, %{
      lease_expires_at: DateTime.add(now(), lease_seconds(resource), :second)
    })
  end

  @doc """
  Re-drives deliveries whose claims died with an expired lease (crash
  between claim and mark). Returns the number re-driven; unexpired leases
  and terminal rows are left alone.

  Rows that cannot be re-driven (inbound declaration removed, provider
  unresolved, a raising handler) are skipped without stopping the sweep —
  a poison row must never starve the rows behind it (cross-vendor finding).
  """
  @spec reap(module()) :: {:ok, non_neg_integer()}
  def reap(resource) do
    now = now()

    expired =
      with_transient_retry(fn ->
        resource
        |> Ash.Query.filter(status == :claimed and lease_expires_at < ^now)
        |> Ash.read!(authorize?: false)
      end)

    Enum.reduce(expired, {:ok, 0}, fn row, {:ok, count} ->
      case safe_redrive(resource, row) do
        {:ok, _} -> {:ok, count + 1}
        _skipped -> {:ok, count}
      end
    end)
  end

  defp safe_redrive(resource, row) do
    redrive(resource, row)
  rescue
    _reason -> {:error, :redrive_crashed}
  end

  # ────────────────────────── internals ──────────────────────────

  defp drive(resource, env, delivery, created?) do
    case claim_delivery(resource, delivery.id) do
      {:error, :lease_held} ->
        {:ok, result(created?), delivery}

      {:error, error} ->
        {:error, error}

      {:ok, _token, claimed} ->
        # The persisted row is the record of truth: a byte-differing
        # redelivery under the same identity drives the FIRST persisted
        # payload, never the new bytes (cross-vendor finding).
        handling_env = row_env(env, delivery)

        handle_and_mark(resource, handling_env, delivery.id, claimed)
        |> case do
          {:ok, final} -> {:ok, result(created?), final}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp handle_and_mark(resource, env, delivery_id, claimed) do
    with {:ok, type} <- env.parsed_type,
         {:ok, _event} <- env.provider.handle_event(type, env.payload) do
      gated_update(resource, delivery_id, claimed.fencing_token, :mark_processed, %{})
    else
      {:error, :unknown_event_type} ->
        gated_update(resource, delivery_id, claimed.fencing_token, :mark_failed, %{
          error_class: "unknown_event_type",
          permanent?: true
        })

      {:error, :malformed_payload} ->
        gated_update(resource, delivery_id, claimed.fencing_token, :mark_failed, %{
          error_class: "malformed_payload",
          permanent?: true
        })

      {:error, kind, term} when kind in [:retry, :permanent] ->
        gated_update(resource, delivery_id, claimed.fencing_token, :mark_failed, %{
          error_class: error_class_string(term),
          permanent?: kind == :permanent
        })

      {:error, error} ->
        {:error, error}
    end
    |> case do
      :ok -> {:ok, reload(resource, delivery_id)}
      {:error, :stale_token} -> {:ok, reload(resource, delivery_id)}
      {:error, error} -> {:error, error}
    end
  end

  # The handling env for a claimed row is rebuilt from the PERSISTED row —
  # payload, digest, and type come from the ledger of record, so a
  # byte-differing redelivery under the same identity can never process
  # bytes the ledger does not show.
  defp row_env(env, row) do
    parsed_type = env.provider.parse_event_type(row.payload)

    %{
      env
      | payload: row.payload,
        digest: row.payload_digest,
        external_event_id: row.external_event_id,
        parsed_type: parsed_type,
        type_string: type_string(parsed_type)
    }
  end

  # The reaper drives rows that already passed verification at ingest — no
  # signature to check, so it rebuilds the handling env from the stored row.
  defp redrive(resource, row) do
    with {:ok, inbound} <- fetch_inbound(resource, row.provider),
         {:ok, provider} <- resolve_provider(inbound, row.provider),
         {:ok, _token, claimed} <- claim_delivery(resource, row.id) do
      parsed_type = provider.parse_event_type(row.payload)

      handle_and_mark(resource, redrive_env(row, provider, parsed_type), row.id, claimed)
    end
  end

  defp redrive_env(row, provider, parsed_type) do
    %{
      name: row.provider,
      provider: provider,
      inbound: nil,
      payload: row.payload,
      digest: row.payload_digest,
      external_event_id: row.external_event_id,
      parsed_type: parsed_type,
      type_string: type_string(parsed_type),
      scope: %{}
    }
  end

  defp reload(resource, delivery_id) do
    # the reload after a successful mark must not crash the caller for a
    # delivered-and-processed event under read contention (consumer journal
    # modes can block readers on writers)
    with_transient_retry(fn ->
      Ash.get!(resource, delivery_id, authorize?: false)
    end)
  end

  defp gated_update(resource, delivery_id, token, action, input) do
    result =
      with_transient_retry(fn ->
        resource
        |> Ash.Query.filter(
          id == ^delivery_id and fencing_token == ^token and status == :claimed and
            lease_expires_at > ^now()
        )
        |> Ash.bulk_update(action, input,
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic]
        )
      end)

    case result do
      %Ash.BulkResult{status: :success, records: [_]} -> :ok
      %Ash.BulkResult{status: :success, records: []} -> {:error, :stale_token}
      %Ash.BulkResult{errors: [error | _]} -> {:error, error}
      %Ash.BulkResult{} -> {:error, {:action_failed, action}}
    end
  end

  defp result(true), do: :created
  defp result(false), do: :duplicate

  # Bounded wall-clock retry for transient sqlite write-lock contention:
  # while the result's error classifies as exqlite busy/locked and the
  # deadline holds, sleep a jittered spacing and re-run. Every other result —
  # ok, :lease_held, :stale_token, any non-busy error — returns immediately;
  # the classifier is the whole safety story.
  defp with_transient_retry(fun),
    do: with_transient_retry(fun, System.monotonic_time(:millisecond))

  defp with_transient_retry(fun, started_at) do
    result = fun.()

    if transient_retryable?(result) and
         System.monotonic_time(:millisecond) - started_at < @transient_retry_deadline_ms do
      Process.sleep(@transient_retry_spacing_ms + :rand.uniform(@transient_retry_jitter_ms))
      with_transient_retry(fun, started_at)
    else
      result
    end
  end

  defp transient_retryable?({:error, error}), do: transient_sqlite_contention?(error)

  defp transient_retryable?(%Ash.BulkResult{status: :error, errors: [_ | _] = errors}),
    do: Enum.all?(errors, &transient_sqlite_contention?/1)

  defp transient_retryable?(_other), do: false

  # exqlite surfaces busy/locked as a string-wrapped
  # Ash.Error.Unknown.UnknownError (probe 2026-08-21); match its text
  # narrowly so only sqlite contention ever retries.
  defp transient_sqlite_contention?(%Ash.Error.Unknown{} = error) do
    Enum.any?(error.errors, &transient_sqlite_contention?/1)
  end

  defp transient_sqlite_contention?(%Ash.Error.Unknown.UnknownError{error: inner}) do
    # splode's to_class flatten path can store a raw non-string term here;
    # `to_string` would raise Protocol.UndefinedError and relabel the real
    # error — inspect it instead (cross-vendor finding, swept from the
    # dispatcher sibling).
    inner = if is_binary(inner), do: inner, else: inspect(inner)
    String.contains?(inner, "Exqlite.Error") and contentiously_busy?(inner)
  end

  defp transient_sqlite_contention?(_other), do: false

  defp contentiously_busy?(inner) do
    down = String.downcase(inner)
    String.contains?(down, "database busy") or String.contains?(down, "database is locked")
  end

  # resolve/4: provider + inbound entity + secret + verification + decode +
  # digest + external id + parsed type. Nothing here writes to the ledger.
  # A signature-valid but undecodable body is NOT rejected: it persists
  # (payload %{}) and is marked permanently malformed after the claim — the
  # provider demonstrably sent it, so the ledger records it.
  defp resolve(resource, name, raw_body, ctx) do
    with {:ok, inbound} <- fetch_inbound(resource, name),
         {:ok, provider} <- resolve_provider(inbound, name),
         :ok <- check_replay_window(inbound, provider, name),
         {:ok, secret} <- resolve_secret(provider, inbound, name, ctx),
         :ok <- check_raw_body(raw_body, name),
         :ok <- verify(provider, raw_body, ctx, inbound, secret, name),
         :ok <- check_scope(resource, ctx) do
      digest = content_digest(raw_body)

      {payload, parsed_type} = decode_and_parse(provider, raw_body)

      {:ok,
       %{
         name: name,
         provider: provider,
         inbound: inbound,
         payload: payload,
         digest: digest,
         external_event_id: external_event_id(inbound, payload, digest),
         parsed_type: parsed_type,
         type_string: type_string(parsed_type),
         scope: declared_scope(resource, ctx)
       }}
    end
  end

  # Batch vendors (HubSpot) deliver top-level JSON ARRAYS; providers that
  # only accept maps fail lists closed through their own catch-all clauses
  # ({:error, :malformed_payload}) — the shape decision belongs to the
  # provider, not the pipeline.
  defp decode_and_parse(provider, raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) or is_list(payload) ->
        {payload, provider.parse_event_type(payload)}

      {:ok, _scalar} ->
        {%{}, {:error, :malformed_payload}}

      {:error, _} ->
        {%{}, {:error, :malformed_payload}}
    end
  end

  defp fetch_inbound(resource, name) do
    case Info.inbound(resource, name) do
      nil ->
        {:error,
         UnknownError.exception(
           error:
             "no inbound #{inspect(name)} declaration on #{inspect(resource)} — add one under `webhooks`"
         )}

      inbound ->
        {:ok, inbound}
    end
  end

  defp resolve_provider(inbound, name) do
    candidate =
      inbound.provider ||
        Module.concat(AshHooks.Provider, Macro.camelize(Atom.to_string(name)))

    if Code.ensure_loaded?(candidate) and function_exported?(candidate, :verify_signature, 3) do
      {:ok, candidate}
    else
      {:error,
       UnknownError.exception(
         error:
           "provider #{inspect(candidate)} does not exist or does not implement " <>
             "AshHooks.Provider — set the `provider` option on the inbound declaration"
       )}
    end
  end

  # Runtime backstop for the compile-time verifier: a window on a
  # timestamp-less scheme silently verifies replays forever — reject before
  # anything runs. The verifier cannot see providers that were not loadable
  # at compile time; this check always can (cross-vendor finding).
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
             "(AshHooks.Provider.timestamp_header/1 is nil) — remove the window or implement the callback"
       )}
    end
  end

  defp resolve_secret(provider, inbound, name, ctx) do
    if Provider.secret_scope(provider) == :per_connection do
      case provider.webhook_signing_secret(ctx[:connection]) do
        {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
        _else -> secret_error(name)
      end
    else
      resolve_secret_source(inbound.secret, name)
    end
  end

  defp resolve_secret_source({m, f, a}, name) do
    case apply(m, f, a) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _else -> secret_error(name)
    end
  end

  defp resolve_secret_source({:app_env, [app | rest]}, name) do
    value = get_in(Application.get_all_env(app), rest)

    case value do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _else -> secret_error(name)
    end
  end

  defp resolve_secret_source(fun, name) when is_function(fun, 0) do
    case fun.() do
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
  defp verify(provider, raw_body, %{signature: signature} = ctx, inbound, secret, name)
       when is_binary(signature) do
    verify_ctx =
      %{
        signature: ctx[:signature],
        headers: ctx[:headers] || %{},
        method: ctx[:method],
        request_uri: ctx[:request_uri]
      }
      |> maybe_put_replay_window(inbound)

    case provider.verify_signature(raw_body, verify_ctx, secret) do
      :ok -> :ok
      {:error, reason} -> {:error, Errors.from_reason(reason, provider: name)}
    end
  end

  defp verify(_provider, _raw_body, _ctx, _inbound, _secret, name) do
    {:error, Errors.from_reason(:invalid_signature, provider: name)}
  end

  defp maybe_put_replay_window(verify_ctx, %{replay_window_seconds: nil}), do: verify_ctx

  defp maybe_put_replay_window(verify_ctx, %{replay_window_seconds: window}),
    do: Map.put(verify_ctx, :replay_window_seconds, window)

  # Scope carries values for the DECLARED slots and nothing else: keys are
  # taken by allowlist, so caller scope data can never overwrite the
  # verified ledger identity fields (cross-vendor finding), and unknown keys
  # are rejected rather than silently shaping the ingest input.
  defp check_scope(resource, ctx) do
    scope = Map.new(ctx[:scope] || %{})
    declared = Extension.get_opt(resource, [:inbound_delivery], :scope_identity, [])

    known = MapSet.new(declared, &Atom.to_string/1)

    unknown =
      scope
      |> Map.keys()
      |> Enum.reject(fn key -> MapSet.member?(known, to_string(key)) end)

    missing =
      Enum.filter(declared, fn slot ->
        not Map.has_key?(scope, slot) and not Map.has_key?(scope, Atom.to_string(slot))
      end)

    cond do
      unknown != [] ->
        {:error,
         MalformedPayload.exception(
           detail:
             "unknown scope keys #{inspect(unknown)} — scope carries only declared scope_identity slots"
         )}

      missing != [] ->
        {:error,
         MalformedPayload.exception(detail: "missing scope values for #{inspect(missing)}")}

      true ->
        :ok
    end
  end

  defp declared_scope(resource, ctx) do
    scope = Map.new(ctx[:scope] || %{})
    declared = Extension.get_opt(resource, [:inbound_delivery], :scope_identity, [])

    Map.new(declared, fn slot ->
      value =
        cond do
          Map.has_key?(scope, slot) -> Map.fetch!(scope, slot)
          Map.has_key?(scope, Atom.to_string(slot)) -> Map.fetch!(scope, Atom.to_string(slot))
        end

      {slot, value}
    end)
  end

  defp content_digest(raw_body),
    do: :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)

  defp external_event_id(inbound, payload, digest) do
    extractor = inbound.event_id

    id =
      if is_function(extractor, 1) do
        case extractor.(payload) do
          # attribute cap is 255 — a longer id hashes to a bounded,
          # deterministic identity instead of erroring on every delivery
          {:ok, id} when is_binary(id) and byte_size(id) <= 255 -> id
          {:ok, id} when is_binary(id) -> content_digest(id)
          _else -> nil
        end
      else
        nil
      end

    id || digest
  end

  defp type_string({:ok, type}) when is_atom(type), do: Atom.to_string(type)
  defp type_string(_), do: nil

  # error_class is a bounded classification field, never an arbitrary dump:
  # binaries truncate, atoms name themselves, and structures (which can carry
  # payloads or secrets) classify without their contents (cross-vendor
  # finding).
  defp error_class_string(term) when is_binary(term), do: String.slice(term, 0, 255)
  defp error_class_string(term) when is_atom(term), do: Atom.to_string(term)
  defp error_class_string(_term), do: "unclassified"

  # Second-truncated UTC: sqlite stores TEXT ISO8601 and compares lexically —
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
