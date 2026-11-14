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

  @doc """
  Returns the value from `{:ok, value}` or `:ok`. Raises a converted error for
  `{:error, error}` or `:error`, and `ArgumentError` for other result shapes.

  Accepts `:error_opts` for error conversion and `:unknown_error_opts` when
  the result is `:error`. See `Splode` for the error-conversion contract.
  """
  def unwrap!(result, opts)

  @doc """
  Calls the function for each leaf error and returns a nested map grouped
  by error path. See `Splode.traverse_errors/2` for the traversal contract.
  """
  def traverse_errors(error_or_errors, fun)

  alias AshHooks.Errors.Invalid.{
    InvalidSignature,
    KeyKindMismatch,
    MalformedPayload,
    NoWebhookSecret,
    StaleTimestamp,
    UnknownEventType,
    UnknownKey,
    UnknownSource
  }

  alias AshHooks.Errors.Unknown.{KeyUnavailable, UnknownError}

  @doc """
  Maps a provider callback's reason atom (the `{:error, reason}` shape the
  behavior returns) to its splode error. Known provider reasons pass `opts`
  through to `exception/1`; the custody classes ignore options.

  Unmapped reasons become a contents-free `UnknownError`; backend terms are
  never included in that error.
  """
  @spec from_reason(term(), Keyword.t()) :: struct()
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

  def from_reason(:unknown_source, _opts), do: UnknownSource.exception([])
  def from_reason(:key_kind_mismatch, _opts), do: KeyKindMismatch.exception([])
  def from_reason(:unknown_key, _opts), do: UnknownKey.exception([])
  def from_reason(:key_unavailable, _opts), do: KeyUnavailable.exception([])

  def from_reason(_other, _opts), do: unknown_error()

  @doc false
  @spec from_custody_result(term()) ::
          :ok | {:ok, term()} | {:error, struct() | atom()}
  def from_custody_result(:ok), do: :ok
  def from_custody_result({:ok, value}), do: {:ok, value}

  def from_custody_result({:error, :invalid_signature}),
    do: {:error, InvalidSignature.exception([])}

  def from_custody_result({:error, :unavailable}), do: {:error, KeyUnavailable.exception([])}
  def from_custody_result({:error, :unknown_ref}), do: {:error, UnknownKey.exception([])}

  def from_custody_result({:error, reason})
      when reason in [:kind_mismatch, :not_signable, :no_public_half],
      do: {:error, KeyKindMismatch.exception([])}

  def from_custody_result({:error, reason})
      when reason in [:no_fingerprint, :invalid_material, :tenant_mismatch],
      do: {:error, reason}

  def from_custody_result({:error, :ref_destroyed}), do: {:error, :key_issue_expired}
  def from_custody_result(_other), do: {:error, unknown_error()}

  defp unknown_error, do: UnknownError.exception(error: "unrecognized webhook failure")
end
