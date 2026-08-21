defmodule AshHooks.Provider.ComplyCube do
  @moduledoc """
  ComplyCube webhook verifier: lowercase-hex HMAC-SHA256 of the RAW request
  body under the webhook endpoint's secret, carried in the
  `ComplyCube-Signature` header — no timestamp, no replay window (verified
  against the vendor docs and all three official SDKs; the acceptance vector
  is the PHP SDK's own test fixture, quoted in
  `test/ash_hooks/provider/comply_cube_test.exs`).

  The scheme is exactly "lowercase-hex HMAC over the raw body", so
  `verify_signature/3` delegates to `Provider.default_verify_signature/4`:
  constant-time compare behind a byte-size guard, case-sensitive on the hex
  (the strict Python/PHP SDKs compare case-sensitively — Node's uppercase
  acceptance is hex-decode leniency, not evidence of uppercase emission), and
  an empty secret fails closed as `{:error, :no_webhook_secret}`. Sign the raw
  body bytes exactly as received — re-serialized JSON with different
  whitespace fails verification.

  `parse_event_type/1` maps the vendor's documented event types to pre-existing
  atoms via an allowlist — unknown type strings fail closed as
  `{:error, :unknown_event_type}` (no atom-table growth from webhook input).
  The consequence is deliberate: a NEW vendor event type the map does not know
  lands in the ledger as `failed_permanent` with `error_class`
  `"unknown_event_type"` — recorded and auditable, but not re-processed
  automatically. Extend `@event_types` (one module attribute) when ComplyCube
  publishes new types, or write a permissive provider module against
  `AshHooks.Provider` if your consumer wants different semantics.

  The optional secret callbacks are deliberately NOT implemented: ComplyCube
  issues one secret per configured webhook endpoint, and an `inbound`
  declaration IS one endpoint — supply it through the DSL `secret` source.
  `timestamp_header/0` is likewise not implemented: a `replay_window_seconds`
  on a ComplyCube inbound is rejected at compile time (the scheme has no
  trustworthy timestamp to window over).
  """

  alias AshHooks.Provider

  defmodule Event do
    @moduledoc "Typed event echoed by `AshHooks.Provider.ComplyCube.handle_event/2`."

    defstruct [:type, :payload]

    @type t :: %__MODULE__{type: atom(), payload: map()}
  end

  @behaviour Provider

  # Vendor-documented taxonomy (API reference, verified first-hand 2026-08-21;
  # identical to the reference platform adapter's production set).
  @event_types %{
    "client.created" => :client_created,
    "client.updated" => :client_updated,
    "client.deleted" => :client_deleted,
    "document.created" => :document_created,
    "document.updated" => :document_updated,
    "document.updated.image_uploaded" => :document_updated_image_uploaded,
    "document.updated.image_deleted" => :document_updated_image_deleted,
    "document.deleted" => :document_deleted,
    "address.created" => :address_created,
    "address.updated" => :address_updated,
    "address.deleted" => :address_deleted,
    "check.pending" => :check_pending,
    "check.completed" => :check_completed,
    "check.completed.clear" => :check_completed_clear,
    "check.completed.attention" => :check_completed_attention,
    "check.completed.rejected" => :check_completed_rejected,
    "check.completed.match_confirmed" => :check_completed_match_confirmed,
    "check.monitoring.attention" => :check_monitoring_attention,
    "check.failed" => :check_failed,
    "check.updated" => :check_updated,
    "workflow.session.started" => :workflow_session_started,
    "workflow.session.cancelled" => :workflow_session_cancelled,
    "workflow.session.processing" => :workflow_session_processing,
    "workflow.session.completed" => :workflow_session_completed,
    "workflow.session.updated" => :workflow_session_updated
  }

  @impl Provider
  def verify_signature(raw_body, ctx, secret) do
    Provider.default_verify_signature(raw_body, ctx.signature, secret, :hmac_sha256)
  end

  @impl Provider
  def parse_event_type(%{"type" => raw}) when is_binary(raw) do
    case Map.fetch(@event_types, raw) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unknown_event_type}
    end
  end

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  @impl Provider
  def handle_event(event_type, payload) do
    {:ok, %Event{type: event_type, payload: payload}}
  end
end
