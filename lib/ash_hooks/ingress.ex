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
  composition and monitoring — the async runtime (#delivery-runtime slice)
  and the reaper drive the same steps.

  All ledger operations run unauthorized: the signature verification IS the
  trust boundary for writes, and external read surfaces remain governed by
  the consumer's own policies (ADR-0005).
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

  # ────────────────────────── sync pipeline ──────────────────────────

  @doc """
  Drives one inbound delivery through the full sync pipeline.
  """
  @spec ingest(module(), atom(), binary() | nil, ctx()) ::
          {:ok, :created | :duplicate, struct()} | {:error, term()}
  def ingest(resource, name, raw_body, ctx) do
    with {:ok, env} <- resolve(resource, name, raw_body, ctx),
         {:ok, created?, delivery} <- ingest_delivery(resource, env) do
      drive(resource, env, delivery, created?)
    end
  end

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

    case Ash.create(resource, input, action: :ingest, authorize?: false) do
      {:ok, delivery} -> {:ok, delivery.id == id, delivery}
      {:error, error} -> {:error, error}
    end
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
    now = now()
    lease_expires_at = DateTime.add(now, lease_seconds(resource), :second)

    result =
      resource
      |> Ash.Query.filter(
        id == ^delivery_id and
          (status == :received or status == :failed_retryable or
             (status == :claimed and lease_expires_at < ^now))
      )
      |> Ash.bulk_update(:claim, %{lease_expires_at: lease_expires_at},
        authorize?: false,
        return_records?: true,
        strategy: [:atomic]
      )

    case result do
      %Ash.BulkResult{status: :success, records: [delivery]} ->
        {:ok, delivery.fencing_token, delivery}

      %Ash.BulkResult{status: :success, records: []} ->
        {:error, :lease_held}

      %Ash.BulkResult{errors: [error | _]} ->
        {:error, error}

      %Ash.BulkResult{} ->
        {:error, :claim_failed}
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
      resource
      |> Ash.Query.filter(status == :claimed and lease_expires_at < ^now)
      |> Ash.read!(authorize?: false)

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
    Ash.get!(resource, delivery_id, authorize?: false)
  end

  defp gated_update(resource, delivery_id, token, action, input) do
    result =
      resource
      |> Ash.Query.filter(
        id == ^delivery_id and fencing_token == ^token and status == :claimed and
          lease_expires_at > ^now()
      )
      |> Ash.bulk_update(action, input,
        authorize?: false,
        return_records?: true,
        strategy: [:atomic]
      )

    case result do
      %Ash.BulkResult{status: :success, records: [_]} -> :ok
      %Ash.BulkResult{status: :success, records: []} -> {:error, :stale_token}
      %Ash.BulkResult{errors: [error | _]} -> {:error, error}
      %Ash.BulkResult{} -> {:error, {:action_failed, action}}
    end
  end

  defp result(true), do: :created
  defp result(false), do: :duplicate

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

  defp decode_and_parse(provider, raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = payload} ->
        {payload, provider.parse_event_type(payload)}

      {:ok, _non_map} ->
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
