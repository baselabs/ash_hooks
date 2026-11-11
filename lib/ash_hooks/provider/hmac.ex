defmodule AshHooks.Provider.Hmac do
  @moduledoc """
  A host-configured HMAC verifier for an emitter whose wire contract you own.

  This is not a vendor protocol. `verify_signature/3` defaults to lowercase-hex
  HMAC-SHA256 over the raw bytes and reads `ctx.signature`. Its four-argument
  form accepts trusted host options:

    * `:header` — signature header name, case-insensitive; when set, only that
      header is used, never a fallback signature from another source.
    * `:algorithm` — `:sha256` (default) or `:sha1`.
    * `:encoding` — `:hex` (lowercase, default) or `:base64`.
    * `:timestamp_header` — optional Unix-seconds header. When configured,
      the default signed input becomes `timestamp <> "." <> raw_body`.
    * `:tolerance_seconds` — positive replay tolerance, default 300, symmetric
      about the runtime clock. A timestamp without a valid MAC never verifies.
    * `:canonical_input` — `{module, function}` or a two-argument function
      `(raw_body, ctx) -> binary`. Replaces the default signed input; the host
      must bind every field its emitter signs, including the timestamp when
      enabled. Never obtain this callback or these options from the request.
    * `:previous_secrets` — additional nonempty binary keys during rotation.
      The third argument may also be a list of current/overlap keys. Empty
      keys never verify. Ingress's `previous_secret` source is another option.

  Comparisons are constant time behind an equal-length guard. The verifier
  keeps no state and never resolves network keys. Malformed inputs and callback
  failures return an error without exposing their contents.

  Algorithm known answers are published in [RFC 4231](https://www.rfc-editor.org/rfc/rfc4231)
  (SHA-256) and [RFC 2202](https://www.rfc-editor.org/rfc/rfc2202) (SHA-1).

  To configure ingress, implement a host provider that delegates verification
  with these options and implements its own parsing and idempotent handling.
  Delegate `timestamp_header/0` to your configured timestamp header if you use
  a DSL replay window, and pass that window as `:tolerance_seconds`.
  Without a wrapper this provider returns `AshHooks.Provider.Event`.
  """

  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}

  @impl true
  def verify_signature(body, ctx, secret), do: verify_signature(body, ctx, secret, [])

  @doc "Verifies using the host's explicit emitter contract and overlap keys."
  @spec verify_signature(binary(), map(), binary() | [binary()], keyword()) ::
          :ok | {:error, :invalid_signature | :no_webhook_secret | :stale_timestamp}
  def verify_signature(body, ctx, secret, opts) do
    with true <- is_binary(body) and is_map(ctx) and Keyword.keyword?(opts),
         {:ok, digest} <- digest(Keyword.get(opts, :algorithm, :sha256)),
         encoding when encoding in [:hex, :base64] <- Keyword.get(opts, :encoding, :hex),
         {:ok, secrets} <- secrets(secret, Keyword.get(opts, :previous_secrets, [])),
         signature when is_binary(signature) <- signature(ctx, opts),
         {:ok, input} <- input(body, ctx, opts),
         true <- matches?(input, signature, secrets, digest, encoding) do
      timestamp_check(ctx, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  catch
    _, _ -> {:error, :invalid_signature}
  end

  defp digest(:sha256), do: {:ok, :sha256}
  defp digest(:sha1), do: {:ok, :sha}
  defp digest(_), do: {:error, :invalid_signature}

  defp secrets(current, previous) when is_list(previous) do
    keys = Enum.filter(List.wrap(current) ++ previous, &(is_binary(&1) and &1 != ""))
    if keys == [], do: {:error, :no_webhook_secret}, else: {:ok, Enum.uniq(keys)}
  end

  defp secrets(_, _), do: {:error, :invalid_signature}

  defp signature(ctx, opts) do
    case Keyword.fetch(opts, :header) do
      {:ok, name} -> Signature.header(ctx, name)
      :error -> ctx[:signature]
    end
  end

  defp input(body, ctx, opts) do
    value =
      case opts[:canonical_input] do
        {m, f} when is_atom(m) and is_atom(f) -> apply(m, f, [body, ctx])
        fun when is_function(fun, 2) -> fun.(body, ctx)
        nil -> default_input(body, ctx, opts[:timestamp_header])
        _ -> nil
      end

    if is_binary(value), do: {:ok, value}, else: {:error, :invalid_signature}
  end

  defp default_input(body, _ctx, nil), do: body

  defp default_input(body, ctx, name) do
    case Signature.header(ctx, name) do
      timestamp when is_binary(timestamp) -> timestamp <> "." <> body
      _ -> nil
    end
  end

  defp matches?(input, signature, keys, digest, encoding) do
    Enum.reduce(keys, false, fn key, matched ->
      Signature.hmac(input, signature, key, digest, encoding) == :ok or matched
    end)
  end

  defp timestamp_check(ctx, opts) do
    case opts[:timestamp_header] do
      nil ->
        :ok

      name ->
        Signature.check_timestamp(
          Signature.header(ctx, name),
          ctx,
          Keyword.get(opts, :tolerance_seconds, 300)
        )
    end
  end

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
