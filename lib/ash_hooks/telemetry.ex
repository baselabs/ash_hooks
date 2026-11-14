defmodule AshHooks.Telemetry do
  @moduledoc """
  Lifecycle events for ingress, queue admission, and outbound delivery.

  Events carry identifiers, measurements, fixed atoms, and classified reasons.
  The package omits bodies, payloads, and resolved signing secrets. For a
  secret fingerprint in your own event, `AshHooks.Telemetry.fingerprint/1`
  returns an eight-character hexadecimal value; package events do not use it.

  Attach handlers to consume these best-effort `:telemetry.execute/3` events:

    * `[:ash_hooks, :ingress, :verify]`: `%{duration_ms}`; `%{source,
      outcome: :ok | :invalid, reason: atom | nil}` (the underscored error-struct name, such as `:invalid_signature` or
      `:unknown_error`; paused sources use `:source_paused`; success uses nil)
    * `[:ash_hooks, :ingress, :dedup]`: `%{source, outcome: :created |
      :duplicate}`
    * `[:ash_hooks, :ingress, :claim]`: `%{source, outcome: :claimed |
      :lease_held}`
    * `[:ash_hooks, :dispatch, :enqueue_failed]`: `%{endpoint_id,
      event_uuid, reason}` (classified, contents-free)
    * `[:ash_hooks, :delivery, :attempt]`: `%{endpoint_id, event_uuid,
      attempts}`
    * `[:ash_hooks, :delivery, :result]`: `%{endpoint_id, event_uuid,
      status: :succeeded | :failed_retryable | :dead_letter,
      response_status: integer | nil, reason: binary | nil}`
    * `[:ash_hooks, :delivery, :backoff]`: `%{endpoint_id, event_uuid,
      attempts, delay_seconds}`
    * `[:ash_hooks, :delivery, :dead_letter]`: `%{endpoint_id,
      event_uuid, reason, response_status}`
    * `[:ash_hooks, :delivery, :disable]`: `%{endpoint_id, reason:
      :gone_410}`
    * `[:ash_hooks, :worker, :invalid_runtime_config]`: `%{reason:
      binary}` (the fixed validation vocabulary: `callback_failed`,
      `unknown_key`, `not_positive_integer`, `backoff_inversion`,
      `envelope_exceeded`, `oban_ceiling_exceeded`); the job failed before
      any delivery work and the delivery row is untouched
    * `[:ash_hooks, :attempt, :record_failed]`: `%{endpoint_id,
      event_uuid, reason}` (classified): an attempt-history row could not
      be written; the delivery's result transition completed, but storing its
      attempt-history row failed
    * `[:ash_hooks, :delivery, :resend]`: `%{endpoint_id, event_uuid,
      requested_by}`: a terminal delivery was re-armed, or event-log replay created its first delivery
    * `[:ash_hooks, :delivery, :test]`: `%{endpoint_id, type}`: a signed
      synthetic test event is about to send (outside subscriptions; the
      payload marks itself when synthesized)
    * `[:ash_hooks, :endpoint, :roll]`: `%{endpoint_id}`: an endpoint's
      signing secret reference was rolled (the overlap window began)
    * `[:ash_hooks, :event, :record_failed]`: `%{event_uuid, reason}`
      (classified): the event log could not record a dispatched event;
      the fanout was unaffected
    * `[:ash_hooks, :endpoint, :disable_warning]`: `%{endpoint_id,
      failure_share, attempts}`: the sustained-failure policy sees an
      endpoint failing at the warning thresholds; notify before the
      breaker opens
    * `[:ash_hooks, :endpoint, :disable]`: `%{endpoint_id, reason}`:
      confirmed sustained-failure disables (`:sustained_failure`), emitted only
      after the write succeeds. HTTP 410 disablement uses
      `[:ash_hooks, :delivery, :disable]`

  `:telemetry.execute/3` matches exact event names, so consume the
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
        [:ash_hooks, :delivery, :disable],
        [:ash_hooks, :worker, :invalid_runtime_config],
        [:ash_hooks, :attempt, :record_failed],
        [:ash_hooks, :delivery, :resend],
        [:ash_hooks, :delivery, :test],
        [:ash_hooks, :endpoint, :roll],
        [:ash_hooks, :endpoint, :disable_warning],
        [:ash_hooks, :endpoint, :disable],
        [:ash_hooks, :event, :record_failed]
      ], fn event, measurements, metadata, _ ->
        # Forward these measurements and identifiers to your metrics system.
      end, nil)
  """

  @doc """
  Returns the first eight hexadecimal characters of a secret's SHA-256 hash
  for correlation. Collisions are possible; do not use this fingerprint as a
  unique identifier or authentication credential.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(secret) when is_binary(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  @doc """
  Classifies reasons using the recognized reason vocabulary and valid HTTP
  status tokens. Recognized strings and atoms pass through regardless of origin.
  Other values become `unclassified`. This function does not distinguish
  package-generated tokens from caller-supplied values.
  """
  @spec classify_token(term()) :: binary()
  @reason_tokens ~w(adapter_crash closed connect_timeout deadline_exceeded
    destination_denied destination_policy_failed delivery_headers_failed
    reserved_delivery_header invalid_header_name invalid_header_value
    certificate_pin_resolution_failed certificate_pin_requires_bounded
    certificate_pin_mismatch invalid_certificate_pin certificate_pin_requires_https
    eacces econnrefused econnreset ehostunreach einval enetunreach enoent
    etimedout endpoint_disabled endpoint_gone endpoint_replaced gone_410
    invalid_destination invalid_event invalid_enqueue_result invalid_enqueuer
    invalid_headers invalid_method invalid_response invalid_route invalid_url
    max_attempts no_secret nxdomain reconcile_pending resolve_timeout
    secret_resolution signing_failed source_conflict stale_row timeout
    tls_alert truncated_body unsafe_destination unresolved_host
    unresolved_route worker_route_mismatch)

  def classify_token(term) when is_atom(term), do: classify_token(Atom.to_string(term))

  def classify_token(term) when is_binary(term) do
    if term in @reason_tokens or http_reason?(term),
      do: term,
      else: "unclassified"
  end

  def classify_token(_other), do: "unclassified"

  defp http_reason?("http_" <> status), do: status_code?(status, 100..599)
  defp http_reason?("redirect_refused_" <> status), do: status_code?(status, 300..399)
  defp http_reason?(_other), do: false

  defp status_code?(<<_a, _b, _c>> = status, range) do
    case Integer.parse(status) do
      {code, ""} -> code in range
      _invalid -> false
    end
  end

  defp status_code?(_other, _range), do: false
end
