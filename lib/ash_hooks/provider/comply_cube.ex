defmodule AshHooks.Provider.ComplyCube do
  @moduledoc """
  Verifies ComplyCube signatures and parses webhook events.

  Configure the webhook endpoint's secret as the inbound declaration's
  `secret`. `ComplyCube-Signature` carries a lowercase hexadecimal HMAC-SHA256
  of the raw request body. Verification compares the exact bytes and is
  case-sensitive. Re-encoding JSON, even with only whitespace changes,
  changes the signature. An empty secret returns `{:error, :no_webhook_secret}`.

  The signature has no authenticated timestamp. A ComplyCube declaration
  cannot use `replay_window_seconds`; that combination is rejected at compile
  time. Durable event identity and idempotent business actions remain necessary
  for repeated deliveries.

  `parse_event_type/1` maps known type strings to pre-existing atoms. Unknown
  types return `{:error, :unknown_event_type}` and ingress records a permanent
  failure with `error_class: "unknown_event_type"`. A new type requires an
  updated provider type map or your own `AshHooks.Provider` implementation.

  `handle_event/2` returns an `AshHooks.Provider.ComplyCube.Event`. To execute
  application actions during ingress, delegate signature verification and type
  parsing to this module and implement an idempotent handler in your provider.
  """

  alias AshHooks.Provider

  defmodule Event do
    @moduledoc "Typed event echoed by `AshHooks.Provider.ComplyCube.handle_event/2`."

    defstruct [:type, :payload]

    @type t :: %__MODULE__{type: atom(), payload: map()}
  end

  @behaviour Provider

  # Known webhook event types from the ComplyCube API reference.
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
  @doc "Builds a typed ComplyCube event from a verified payload."
  def handle_event(event_type, payload) do
    {:ok, %Event{type: event_type, payload: payload}}
  end
end
