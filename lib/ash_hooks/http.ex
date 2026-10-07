defmodule AshHooks.Http do
  @moduledoc """
  HTTP adapter contract for outbound delivery.

  `request/5` returns `{:ok, %{status: status, headers: headers, body: body}}`
  or `{:error, reason}`. Issue one request and return redirects to the delivery
  runtime for classification. The default adapter is `AshHooks.Http.Bounded`;
  `AshHooks.Http.Httpc` provides an alternative built on OTP's HTTP client.

  ## Writing an adapter

    * Return response headers as a list of `{name, value}` tuples with binary
      names and values. Normalize names to lowercase; conventional `Retry-After`
      and `Content-Type` names are also recognized.
      This shape preserves `Retry-After` and content-type handling; a map
      causes the runtime to use ordinary backoff and the `other` content kind.
    * Resolve-and-pin: resolve through `AshHooks.Ssrf.resolve_public/1` and
      connect to an address from that validated result. Preserve the original
      hostname for TLS certificate verification and SNI, and the original
      authority for the Host header. Resolving again during connection allows
      DNS rebinding between validation and use. Both supplied adapters pin
      their connection address.
    * Bound the complete operation and response memory. Bounded defaults to
      15 seconds for the operation, 32 KiB for headers, and 64 KiB for the body.
      See `AshHooks.Http.Httpc` for its response-buffering limitations.
  """

  @callback request(atom(), String.t(), map(), binary(), keyword()) ::
              {:ok, %{status: integer(), headers: list(), body: binary() | nil}}
              | {:error, term()}
end
