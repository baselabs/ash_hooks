defmodule AshHooks.Telemetry do
  @moduledoc """
  Lifecycle events for ingress, queue admission, outbound delivery, and key disposal.

  Events carry identifiers, measurements, fixed atoms, and classified reasons.
  Package-generated metadata omits bodies, payloads, and resolved signing secrets.
  Ingress failure classes can include host-provided text, as described below. For a
  secret fingerprint in your own event, `AshHooks.Telemetry.fingerprint/1`
  returns an eight-character hexadecimal value; package events do not use it.

  Attach handlers to consume these best-effort `:telemetry.execute/3` events.
  Measurements are `%{}` unless shown separately before the metadata map.
  Outbox events and delivery missing and disable events include the operation's
  `tenant` identifier, or `nil` when absent, so hosts can alarm or notify per tenant.

    * `[:ash_hooks, :egress, :start | :stop]`: measurements
      `%{dns_duration_ms, connect_duration_ms, tls_duration_ms,
      first_byte_duration_ms, total_duration_ms, bytes_sent, bytes_received}`;
      metadata `%{destination_id, scheme, port, address_family, method, phase,
      sent, status, completion, reason}`. Durations are milliseconds; unset
      first-byte duration is nil. Byte counts include HTTP framing;
      `bytes_sent` counts bytes submitted to the write, including a failed
      write whose delivery is unknown. Start has zero counts. Stop classifies the final
      phase and result. Method is an uppercase supported method string or nil.
      The opaque destination ID is the only caller-supplied value. No
      host, path, query, headers, bodies, or raw exception terms are included
    * `[:ash_hooks, :ingress, :verify]`: `%{duration_ms}`; `%{source,
      outcome: :ok | :invalid, reason: atom | nil}` (the underscored error-struct name, such as `:invalid_signature` or
      `:unknown_error`; paused sources use `:source_paused`; success uses nil)
    * `[:ash_hooks, :ingress, :dedup]`: `%{source, outcome: :created |
      :duplicate}`
    * `[:ash_hooks, :ingress, :claim]`: `%{source, outcome: :claimed |
      :lease_held}`
    * `[:ash_hooks, :ingress, :failure]`: `%{count: 1}`; `%{source,
      error_class: binary, permanent?: boolean}` after a failure is recorded;
      stale fencing tokens emit nothing. `error_class` is exactly the bounded
      class recorded on the ledger row, including host-provided classes from
      `{:error, :retry | :permanent, term}`. Valid binary classes are capped at
      255 UTF-8 bytes, atoms use their names, other terms become `unclassified`,
      and invalid UTF-8 becomes `[binary]`. Hosts must not put secrets or payload
      data in this class; it is not restricted to the package's fixed vocabulary
    * `[:ash_hooks, :outbox, :publish]`: `%{count: 1}`; `%{event_uuid,
      outcome: :attempt | :accepted | :duplicate | :refused, reason, tenant}`.
      The after-commit notifier or a successful fanout claim reports committed
      acceptance. Raw repository transactions suppress notifications and rely
      on the sweep
    * `[:ash_hooks, :outbox, :trigger]`: `%{count: 1}`; `%{event_uuid,
      outcome: :failed, reason: "trigger_failed", tenant}`
    * `[:ash_hooks, :outbox, :claim]`: `%{count: 1}`; `%{event_uuid,
      outcome: :claimed | :busy | :stale | :missing | :done | :failed | :error,
      reason, tenant}`. Each fanout reaching the read emits one event for its read or
      claim outcome, including storage errors with a classified reason.
      Missing and already-terminal reads report the requested event ID without
      a state transition. `:claimed` fires when the claim write succeeds,
      before fanout work. A claimed run that loses its fenced lease also emits
      `:stale`. Other outcomes use nil reasons
    * `[:ash_hooks, :outbox, :result]`: `%{count: 1}`; `%{event_uuid,
      outcome: :done | :pending | :failed, reason, tenant}`. Emitted only after the
      matching fenced state transition succeeds
    * `[:ash_hooks, :outbox, :rearm]`: `%{count: 1}`; `%{event_uuid,
      outcome: :pending, reason: nil, tenant}`
    * `[:ash_hooks, :outbox, :sweep]`: `%{count: 1}`; `%{event_uuid: nil,
      outcome: :complete | :error, reason, tenant}`. Reasons use `classify_token/1`;
      outbox events contain no payload or metadata contents
    * `[:ash_hooks, :dispatch, :enqueue_failed]`: `%{endpoint_id,
      event_uuid, reason}` (classified, contents-free)
    * `[:ash_hooks, :delivery, :attempt]`: `%{endpoint_id, event_uuid,
      attempts}`
    * `[:ash_hooks, :delivery, :missing]`: measurement `%{}`; metadata
      contains the job's `endpoint_id`, `event_uuid`, and/or `delivery_pk`, plus
      the resolved `tenant`. The complete job key is preserved, including any
      tenant attribute component.
      No delivery row was visible; the worker returns `{:cancel, :delivery_missing}`.
      Payloads and metadata contents are omitted
    * `[:ash_hooks, :delivery, :sign]`: measurement `%{duration: native_time}`;
      metadata `%{outcome: :ok | :skip | :retry | :terminal | :invalid_result |
      :callback_failed}`. Contains no callback terms or key material.
    * `[:ash_hooks, :delivery, :result]`: `%{endpoint_id, event_uuid,
      status: :succeeded | :failed_retryable | :dead_letter,
      response_status: integer | nil, reason: binary | nil}`
    * `[:ash_hooks, :delivery, :backoff]`: `%{endpoint_id, event_uuid,
      attempts, delay_seconds}`
    * `[:ash_hooks, :delivery, :dead_letter]`: `%{endpoint_id,
      event_uuid, reason, response_status}`
    * `[:ash_hooks, :delivery, :disable]`: `%{endpoint_id, reason:
      :gone_410, tenant}`
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

    * `[:ash_hooks, :endpoint_health, :read_failed]`: measurement `%{count: 1}`;
      metadata `%{endpoint_id, reason}` (classified): attempt history could not be read.
      The sweep increments `unread` and preserves this endpoint's warning marker.
    * `[:ash_hooks, :key_registry, :destroy_failed]`: measurement `%{count: 1}`;
      metadata `%{registry: module, ref: reference, reason: reason}`, where
      `reason` is `:tenant_mismatch` or `:unclassified`. The reference's
      destruction could not complete and requires operator repair and rearming.

  `:telemetry.execute/3` matches exact event names, so consume the
  whole surface with one `attach_many`:


  <!-- not-run: This integration requires the host metrics callback to forward the supplied event data. -->

      :telemetry.attach_many(
        "my-ash-hooks",
        [
          [:ash_hooks, :egress, :start],
          [:ash_hooks, :egress, :stop],
          [:ash_hooks, :ingress, :verify],
          [:ash_hooks, :ingress, :dedup],
          [:ash_hooks, :ingress, :claim],
          [:ash_hooks, :ingress, :failure],
          [:ash_hooks, :outbox, :publish],
          [:ash_hooks, :outbox, :trigger],
          [:ash_hooks, :outbox, :claim],
          [:ash_hooks, :outbox, :result],
          [:ash_hooks, :outbox, :rearm],
          [:ash_hooks, :outbox, :sweep],
          [:ash_hooks, :dispatch, :enqueue_failed],
          [:ash_hooks, :delivery, :attempt],
          [:ash_hooks, :delivery, :missing],
          [:ash_hooks, :delivery, :sign],
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
          [:ash_hooks, :endpoint_health, :read_failed],
          [:ash_hooks, :event, :record_failed],
          [:ash_hooks, :key_registry, :destroy_failed]
        ],
        fn event, measurements, metadata, _ ->
          nil
          # Forward these measurements and identifiers to your metrics system.
        end,
        nil
      )
  """

  @doc """
  Returns the first eight hexadecimal characters of a secret's SHA-256 hash
  for correlation. Collisions are possible; do not use this fingerprint as a
  unique identifier or authentication credential.

  This correlation-only hash has a different domain from display key
  fingerprints. It does not protect a weak or predictable secret from
  offline guessing; show fingerprints only for securely generated keys.
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
    invalid_headers invalid_method invalid_response invalid_route invalid_url inside_transaction
    max_attempts no_secret nxdomain reconcile_pending resolve_timeout
    secret_resolution signing_failed signer_failed adapter_cannot_send_prepared unsigned invalid_prepared_request source_conflict stale_row timeout
    tls_alert truncated_body unsafe_destination unresolved_host
    unresolved_route worker_route_mismatch unknown_source key_kind_mismatch
    unknown_key key_unavailable invalid_signature unknown_error kind_not_allowed
    invalid_publication_metadata publication_conflict nontransactional_outbox
    publication_repository_mismatch unknown_declaration invalid_publication_content
    unsupported_publication_format fanout_crashed fanout_timeout fanout_incomplete
    publication_transition_failed publication_missing publication_not_failed
    invalid_outbox_query trigger_failed enqueue_contended unknown_pinned_version variant_failed)

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
