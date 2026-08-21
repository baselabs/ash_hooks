defmodule AshHooks.Provider do
  @moduledoc """
  Behaviour for inbound webhook providers.

  A provider module owns one vendor's webhook contract: how a delivery's
  signature is verified, where its signing secret lives, how the event type is
  parsed from the payload, and how a payload becomes a typed event.

  `verify_signature/3` implementations whose scheme is exactly "lowercase-hex
  HMAC over the raw body" delegate to `default_verify_signature/4`;
  scheme-specific providers (composite strings, separate timestamp headers,
  replay windows) implement their own.

  This behaviour is the migration boundary for adopting platforms: provider
  modules written against a previous in-house behaviour of this shape migrate
  by alias change — the callback names, arities, context map, and
  `default_verify_signature/4` semantics are kept identical for that reason.
  """

  @type raw_body :: binary()
  @type signature_header_value :: binary()
  @type webhook_secret :: binary()
  @type signature_algorithm :: :hmac_sha256 | :hmac_sha512
  @type signature_error :: :invalid_signature | :no_webhook_secret | :stale_timestamp
  @type parse_error :: :unknown_event_type | :malformed_payload

  @typedoc """
  The request context `verify_signature/3` receives as its second argument.
  Carries everything any provider's signature scheme can need:

    * `:signature` — the value extracted from the provider's signature header.
    * `:headers` — the full lowercased request header map, for schemes that
      read an additional header (e.g. a separate timestamp header).
    * `:method` — the uppercase HTTP method, for schemes that sign over it.
      `nil` when the caller does not supply it.
    * `:request_uri` — the exact request URI the provider signed. `nil` when
      not supplied.

  A provider whose scheme needs only the signature reads `:signature` and
  ignores the rest.
  """
  @type verify_context :: %{
          signature: signature_header_value(),
          headers: %{optional(String.t()) => String.t()},
          method: String.t() | nil,
          request_uri: String.t() | nil
        }

  @typedoc """
  Where a provider's webhook signing secret lives:

    * `:app_level` — one app-wide shared secret signs every connection's
      webhooks. The default when the callback is not implemented.
    * `:per_connection` — each connection carries its own signing secret.
  """
  @type webhook_secret_scope :: :app_level | :per_connection

  @callback verify_signature(raw_body(), verify_context(), webhook_secret()) ::
              :ok | {:error, signature_error()}

  @doc """
  Resolves the signing secret used to verify an inbound webhook.

  The secret SOURCE is provider-dependent, so it lives with the provider
  module rather than in the generic ingress. App-level providers read an
  app-wide config value; per-connection providers read it off the `connection`
  argument. Returns `{:error, :no_webhook_secret}` when unconfigured — the
  caller verifies nothing and does not run the handler.
  """
  @callback webhook_signing_secret(connection :: struct()) ::
              {:ok, webhook_secret()} | {:error, :no_webhook_secret}

  @doc """
  Declares whether this provider's webhook signing secret is app-level
  (the default) or per-connection. Optional.
  """
  @callback webhook_secret_scope() :: webhook_secret_scope()

  @doc """
  The request header this provider's signature scheme carries a trustworthy
  timestamp in (`nil` when the scheme has none). A DSL `replay_window_seconds`
  requires a non-`nil` value here — the compile-time verifier rejects the
  combination otherwise, and there is no replay protection without it.
  Optional, defaulting to `nil`.
  """
  @callback timestamp_header() :: String.t() | nil

  @optional_callbacks webhook_signing_secret: 1, webhook_secret_scope: 0, timestamp_header: 0

  @doc """
  Parses the event type from the DECODED request body — a map for
  object-shaped vendors, a list for batch vendors (HubSpot delivers
  top-level arrays). Providers receiving a shape their vendor never sends
  fail closed through their catch-all clause (`{:error, :malformed_payload}`).
  """
  @callback parse_event_type(payload :: map() | list()) ::
              {:ok, atom()} | {:error, parse_error()}

  @callback handle_event(event_type :: atom(), payload :: map()) ::
              {:ok, typed_event :: struct()}
              | {:error, :retry | :permanent, term()}

  @doc """
  Resolves a provider's webhook secret scope, defaulting to `:app_level` when
  the optional `webhook_secret_scope/0` callback is not implemented.

  Loads the provider module first: `function_exported?/3` reports false for a
  module that is not yet loaded, which would misread an unloaded
  per-connection provider as app-level.
  """
  @spec secret_scope(module()) :: webhook_secret_scope()
  def secret_scope(provider) when is_atom(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :webhook_secret_scope, 0) do
      provider.webhook_secret_scope()
    else
      :app_level
    end
  end

  @doc """
  Resolves a provider's trustworthy timestamp header, defaulting to `nil`
  when the optional `timestamp_header/0` callback is not implemented.

  Loads the provider module first — same unloaded-module guard as
  `secret_scope/1`.
  """
  @spec timestamp_header(module()) :: String.t() | nil
  def timestamp_header(provider) when is_atom(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :timestamp_header, 0) do
      provider.timestamp_header()
    else
      nil
    end
  end

  @doc """
  Default HMAC verify implementation: lowercase-hex HMAC of the raw body under
  the secret, compared in constant time behind a byte-size guard.

  The byte-size guard both short-circuits wrong-length signatures and
  satisfies `:crypto.hash_equals/2`'s equal-length requirement.

  An EMPTY secret fails closed as `{:error, :no_webhook_secret}` — an HMAC
  under the empty key is computable by anyone, so a secret source that quietly
  resolves to `""` must not verify anything.
  """
  @spec default_verify_signature(
          raw_body(),
          signature_header_value(),
          webhook_secret(),
          signature_algorithm()
        ) :: :ok | {:error, :invalid_signature | :no_webhook_secret}

  def default_verify_signature(_raw_body, _header_value, secret, _algorithm)
      when byte_size(secret) == 0,
      do: {:error, :no_webhook_secret}

  def default_verify_signature(raw_body, header_value, secret, algorithm)
      when is_binary(raw_body) and is_binary(header_value) and is_binary(secret) and
             algorithm in [:hmac_sha256, :hmac_sha512] do
    digest = if(algorithm == :hmac_sha256, do: :sha256, else: :sha512)

    expected =
      :crypto.mac(:hmac, digest, secret, raw_body) |> Base.encode16(case: :lower)

    if byte_size(expected) == byte_size(header_value) and
         :crypto.hash_equals(expected, header_value) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
