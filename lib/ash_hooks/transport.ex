defmodule AshHooks.Transport do
  @moduledoc """
  The delivery transport behavior: route one endpoint's deliveries to your
  own transport instead of HTTP — a developer's local forwarder behind a
  CLI "listen" command, a message bus, a test collector — while the SAME
  signing, attempt history, classification, backoff, and telemetry apply,
  because the transport IS the adapter-shaped seam the delivery runtime
  drives.

      defmodule MyApp.CliForwarderTransport do
        @behaviour AshHooks.Transport

        @impl true
        def request(_method, url, headers, body, _opts) do
          # push the signed request to the developer's laptop over your
          # forwarder protocol; answer with the forwarder's HTTP verdict
          MyApp.CliForwarder.send!(url, headers, body)
        end
      end

  Route per endpoint through the worker option (or direct-run config)
  `transport: {module, function}` / a 2-arity fn receiving the endpoint
  record and tenant, returning the transport module (or `nil` to keep the
  HTTP adapter). A resolver that crashes, or a non-module return, falls
  back to the HTTP adapter path — the HTTP guarantees stay the default.

  The callback contract is `AshHooks.Http`'s adapter contract verbatim:
  one `request/5` returning `{:ok, %{status, headers, body}}` or
  `{:error, reason}`; the runtime's classification table (2xx succeeds,
  408/429/5xx retry honoring Retry-After, other 4xx dead-letter, redirects
  refused, transport errors retry) applies unchanged. A destination
  policy allowing the forwarder's URL scheme keeps the send-time gate
  open for it (see `AshHooks.DestinationPolicy`).
  """

  @callback request(atom(), String.t(), map(), binary(), keyword()) ::
              {:ok, %{status: integer(), headers: list(), body: binary() | nil}}
              | {:error, term()}
end
