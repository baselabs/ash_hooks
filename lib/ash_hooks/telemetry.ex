defmodule AshHooks.Telemetry do
  @moduledoc """
  The package's telemetry surface (ADR-0005's telemetry floor): events
  carry ids, integers, fixed-vocabulary atoms, and classified reason
  strings ONLY — never secrets, bodies, or payloads. Where a consumer
  wants secret IDENTITY in an event, `fingerprint/1` is the sanctioned
  8-hex form; no package event needs it today.

  Events (`:telemetry.execute/3`, best-effort; consumers opt in by
  attaching handlers — the telemetry ~> 1.3 floor is a currency floor;
  execute/3's exact-name matching and detach-on-crash behavior were
  verified first-hand against the vendored source):

    * `[:ash_hooks, :ingress, :verify]` — `%{duration_ms}`; `%{source,
      outcome: :ok | :invalid, reason: atom | nil}` (the five
      `AshHooks.Errors.Invalid` classes, or nil for unknown-class
      pre-verify failures)
    * `[:ash_hooks, :ingress, :dedup]` — `%{source, outcome: :created |
      :duplicate}`
    * `[:ash_hooks, :ingress, :claim]` — `%{source, outcome: :claimed |
      :lease_held}`
    * `[:ash_hooks, :dispatch, :enqueue_failed]` — `%{endpoint_id,
      event_uuid, reason}` (classified, contents-free)
    * `[:ash_hooks, :delivery, :attempt]` — `%{endpoint_id, event_uuid,
      attempts}`
    * `[:ash_hooks, :delivery, :result]` — `%{endpoint_id, event_uuid,
      status: :succeeded | :failed_retryable | :dead_letter,
      response_status: integer | nil, reason: binary | nil}`
    * `[:ash_hooks, :delivery, :backoff]` — `%{endpoint_id, event_uuid,
      attempts, delay_seconds}`
    * `[:ash_hooks, :delivery, :dead_letter]` — `%{endpoint_id,
      event_uuid, reason, response_status}`
    * `[:ash_hooks, :delivery, :disable]` — `%{endpoint_id, reason:
      :gone_410}`

  `:telemetry.execute/3` matches EXACT event names (verified against
  telemetry 1.4's source — prefix attaches never fire), so consume the
  whole surface with one `attach_many`:

      :telemetry.attach_many("my-ash-hooks", [
        [:ash_hooks, :ingress, :verify],
        [:ash_hooks, :ingress, :dedup],
        [:ash_hooks, :ingress, :claim],
        [:ash_hooks, :dispatch, :enqueue_failed],
        [:ash_hooks, :delivery, :attempt],
        [:ash_hooks, :delivery, :result],
        [:ash_hooks, :delivery, :backoff],
        [:ash_hooks, :delivery, :dead_letter],
        [:ash_hooks, :delivery, :disable]
      ], fn event, measurements, metadata, _ ->
        # metrics/APM ship — the floor guarantees no secret/body material
      end, nil)
  """

  @doc """
  The sanctioned secret identity for telemetry consumers: SHA-256,
  first 8 hex chars — a non-reversible correlation identity (ADR-0005's
  chosen form; not an authz credential).
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  @doc """
  The shared contents-free error classifier (the delivery and dispatcher
  error strings route through this): atoms are the package's own
  vocabulary; a binary survives only if it is a single fixed-grammar
  token (`\A[a-z][a-z0-9_]*\z`); anything else — consumer resolver,
  adapter, or enqueuer terms that can carry secret or body material —
  collapses to "unclassified".
  """
  @spec classify_token(term()) :: binary()
  def classify_token(term) when is_atom(term), do: Atom.to_string(term)

  def classify_token(term) when is_binary(term) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, term),
      do: String.slice(term, 0, 255),
      else: "unclassified"
  end

  def classify_token(_other), do: "unclassified"
end
