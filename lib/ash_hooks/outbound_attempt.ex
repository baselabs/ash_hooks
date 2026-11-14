defmodule AshHooks.OutboundAttempt do
  @moduledoc """
  Turns the consumer's resource into the outbound attempt history: one
  durable row per delivery attempt, written by the delivery runtime beside
  its fenced result transitions.

      use Ash.Resource,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.OutboundAttempt]

  The extension injects the attempt fields: the complete encoded delivery
  key (`delivery_pk`), `endpoint_id`, `event_uuid`, `event_type`, the
  attempt number (`attempt`), the outcome (`:succeeded | :failed_retryable |
  :dead_letter`), the classified `reason`, `response_status`,
  `response_snippet`, `response_headers` (allowlisted capture only),
  `latency_ms`, `signing_key_ref` (a store reference, never secret material),
  `test`, and `attempted_at`. Every attempted request, including one answered
  with HTTP 410, records its duration and signing-key reference. A 410 disable
  stored before 3.1.0 carries neither, so its finalization records both as nil.
  The extension also injects
  the `unique_attempt` identity on `[:delivery_pk, :attempt]`, which
  makes the runtime's history writes idempotent per attempt. Your
  migration carries the matching unique index.

  Response bodies are never stored here unless the ENDPOINT opted in per
  row (`response_capture_attributes :on` on the endpoint resource and
  `response_capture: true` on the row): an opted-in capture bounds the
  bytes by the endpoint's `response_capture_max_bytes`, passes the
  package's redaction floor, and keeps only response header names in the
  endpoint's `response_header_allowlist`. Without capture, the snippet is
  the fixed no-body summary grammar and `response_headers` is nil.

  The runtime writes through the injected `:record` machine action
  (`authorize?: false`); a history write failure never fails the send;
  it surfaces as `[:ash_hooks, :attempt, :record_failed]` telemetry. The
  delivery row remains the delivery contract; this ledger is the audit
  trail behind the delivery log, health computation, and resend views.

  Read access is yours to govern; the package injects no read policies.
  Rows carry response summaries and (only under per-endpoint opt-in)
  redacted response material.

  Policy obligation: protect the injected `:record` create and `:prune`
  destroy actions wherever your domain exposes the resource; the
  runtime's internal calls bypass authorization by design.
  """

  alias AshHooks.{Keyset, Tenancy}

  require Ash.Query

  @outcomes [:succeeded, :failed_retryable, :dead_letter]

  @doc """
  The attempt outcomes, mirroring the delivery runtime's result states.
  """
  @spec outcomes() :: list(atom())
  def outcomes, do: @outcomes

  @doc """
  Lists attempt rows by filter with keyset pagination (newest first).

  Options:

    * `:endpoint_id`: one endpoint's attempts.
    * `:outcome`: a list of outcomes (e.g. `[:failed_retryable, :dead_letter]`).
    * `:event_type` / `:event_uuid`: the event's type or exact identity.
    * `:test`: `true`/`false`: filter attempts to (or exclude) test sends.
    * `:delivery_pk`: attempts of one delivery (the row's encoded key map).
    * `:from` / `:to`: `DateTime` bounds on `attempted_at` (inclusive).
    * `:limit`: page size (default 50, max 500; anything else is
      `{:error, :invalid_limit}`).
    * `:after`: the cursor from a previous page's `:next_cursor` (a
      malformed cursor is `{:error, :invalid_cursor}`, never a raise).
    * `:tenant`: required on multitenant resources (the named
      `{:error, :tenant_required}` pre-flight otherwise).

  Returns `{:ok, %{records: [row], next_cursor: binary | nil}}`.
  """
  @spec list(module(), keyword()) ::
          {:ok, %{records: [struct()], next_cursor: binary() | nil}} | {:error, term()}
  def list(resource, opts \\ []) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      Keyset.read_page(resource, opts, :attempted_at, &attempt_filters(&1, opts), tenant)
    end
  end

  defp attempt_filters(query, opts) do
    query
    |> optional_eq(:endpoint_id, opts[:endpoint_id])
    |> optional_eq(:event_type, opts[:event_type])
    |> optional_eq(:event_uuid, opts[:event_uuid])
    |> optional_eq(:delivery_pk, opts[:delivery_pk])
    |> optional_eq(:test, opts[:test])
    |> optional_in(:outcome, opts[:outcome])
    |> time_range(opts[:from], opts[:to])
  end

  defp optional_eq(query, _field, nil), do: query

  defp optional_eq(query, field, value) do
    require Ash.Expr
    ref = Ash.Expr.ref(field)
    expression = Ash.Expr.expr(^ref == ^value)
    Ash.Query.filter(query, ^expression)
  end

  defp optional_in(query, _field, nil), do: query

  defp optional_in(query, field, values) when is_list(values) do
    require Ash.Expr
    ref = Ash.Expr.ref(field)
    expression = Ash.Expr.expr(^ref in ^values)
    Ash.Query.filter(query, ^expression)
  end

  defp time_range(query, nil, nil), do: query

  defp time_range(query, from, to) do
    require Ash.Expr
    time = Ash.Expr.ref(:attempted_at)

    lower = if from, do: Ash.Expr.expr(^time >= ^from)
    upper = if to, do: Ash.Expr.expr(^time <= ^to)

    expression =
      case {lower, upper} do
        {one, nil} -> one
        {nil, one} -> one
        {lower, upper} -> Ash.Expr.expr(^lower and ^upper)
      end

    if expression, do: Ash.Query.filter(query, ^expression), else: query
  end

  use Spark.Dsl.Extension,
    transformers: [
      AshHooks.OutboundAttempt.Transformers.AddAttemptFields,
      AshHooks.OutboundAttempt.Transformers.AddAttemptIdentity,
      AshHooks.OutboundAttempt.Transformers.AddAttemptActions
    ],
    verifiers: [AshHooks.Verifiers.MultitenancyNoBypass]
end
