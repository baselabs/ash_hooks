defmodule AshHooks.Telemetry do
  @moduledoc """
  The package's telemetry surface (ADR-0005's telemetry floor): events
  carry ids, integers, fixed-vocabulary atoms, and classified reason
  strings ONLY — never secrets, bodies, or payloads. Where a consumer
  wants secret IDENTITY in an event, `fingerprint/1` is the sanctioned
  8-hex form; no package event needs it today.

  Events (`:telemetry.execute/3`, best-effort; consumers opt in by
  attaching handlers — telemetry ~> 1.3 required, where a crashing
  handler is detached rather than raised into the delivery job):

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

      events =
        for group <- [:ingress, :dispatch, :delivery],
            action <- [:verify, :dedup, :claim, :enqueue_failed, :attempt, :result, :backoff, :dead_letter, :disable] do
          [:ash_hooks, group, action]
        end

      :telemetry.attach_many("my-ash-hooks", events, fn event, measurements, metadata, _ ->
        # metrics/APM ship — the floor guarantees no secret/body material
      end, nil)
  """

  @doc """
  The sanctioned secret identity for telemetry consumers: SHA-256,
  first 8 hex chars — an unbeknownst-to-the-receiver fingerprint that
  cannot be reversed into material.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end
end
