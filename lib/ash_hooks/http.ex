defmodule AshHooks.Http do
  @moduledoc """
  The HTTP adapter behaviour the delivery runtime sends through.

  `request/5` returns `{:ok, %{status: integer, headers: [{name, value}]},
  body :: binary}` or `{:error, term}` — one request, NO redirect
  following (a 3xx must surface as a response the runtime classifies as a
  refused redirect, never be chased). The default implementation is
  `AshHooks.Http.Bounded` (memory-bounded raw sockets); `AshHooks.Http.Httpc`
  (`:httpc`) is the alternative adapter, and tests inject a double.

  ## The adapter-author contract

    * **Header shape:** `headers` MUST be a LIST of `{name, value}` tuples
      with binary values — not a map. The runtime's `Retry-After` and
      content-type reads (`AshHooks.Delivery`) guard on `is_list/1` and
      otherwise degrade SILENTLY to plain backoff and the `other`
      content-kind: a map-shaped header list (e.g. Req 0.7's
      `%{binary => [binary]}`) loses `Retry-After` with no error anywhere.
      Header NAMES may be downcased or Capitalized — both spellings of
      `retry-after`/`content-type` are matched — but the LIST shape is
      required.
    * **Resolve-and-pin (the TOCTOU closure):** an adapter that performs
      its own DNS resolution and connects by hostname re-opens the
      DNS-rebinding window the SSRF floor exists to close (check-then-
      connect uses two different answers). Resolve the hostname ONCE
      through `AshHooks.Ssrf.resolve_public/1` (or `AshHooks.Http.Target.resolve/2`)
      and connect to the VALIDATED address — TLS names the original host,
      the host header carries the original host:port. `AshHooks.Http.Bounded`
      does this; the driver's send-time `ssrf_check` is the RESIDUAL
      guarantee, not a replacement for it.
    * **Bounds:** adapters SHOULD bound their own connect/receive timeouts
      and response memory (Bounded: 32 KiB headers, 64 KiB body) — the
      runtime also runs under the Oban job timeout as the outer bound.
  """

  @callback request(atom(), String.t(), map(), binary(), keyword()) ::
              {:ok, %{status: integer(), headers: list(), body: binary() | nil}}
              | {:error, term()}
end
