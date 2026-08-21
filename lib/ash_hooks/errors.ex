defmodule AshHooks.Errors do
  @moduledoc """
  Splode error hierarchy for ash_hooks.

  Inbound pipeline failures surface as `:invalid`-class errors (bad signature,
  missing secret, stale timestamp, unknown event type, malformed payload).
  Anything unrecognized lands in `:unknown`.
  """

  use Splode,
    error_classes: [
      invalid: AshHooks.Errors.Invalid,
      unknown: AshHooks.Errors.Unknown
    ],
    unknown_error: AshHooks.Errors.Unknown.UnknownError

  alias AshHooks.Errors.Invalid.{
    InvalidSignature,
    MalformedPayload,
    NoWebhookSecret,
    StaleTimestamp,
    UnknownEventType
  }

  @doc """
  Maps a provider callback's reason atom (the `{:error, reason}` shape the
  behaviour returns) to its splode error, passing `opts` through to
  `exception/1`.

  Raises on an unmapped reason — that is a programming error on the caller's
  side, not webhook input.
  """
  @spec from_reason(atom(), Keyword.t()) :: struct()
  def from_reason(:invalid_signature, opts),
    do: InvalidSignature.exception(opts)

  def from_reason(:no_webhook_secret, opts),
    do: NoWebhookSecret.exception(opts)

  def from_reason(:stale_timestamp, opts),
    do: StaleTimestamp.exception(opts)

  def from_reason(:unknown_event_type, opts),
    do: UnknownEventType.exception(opts)

  def from_reason(:malformed_payload, opts),
    do: MalformedPayload.exception(opts)

  def from_reason(other, _opts),
    do: raise(ArgumentError, "unmapped webhook reason: #{inspect(other)}")
end
