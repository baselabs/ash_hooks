defmodule AshHooks.Http.Bounded do
  @moduledoc """
  The default `AshHooks.Http` adapter: HTTP/1.1 over `:gen_tcp` and `:ssl`,
  with bounded response collection and one operation deadline.

  Each connection carries one request with `Connection: close`. The adapter
  returns redirects without following them and consumes informational responses
  before the final response, with a default limit of eight interim responses.
  It connects to a validated, pinned IP address while retaining the original
  host for the HTTP authority, TLS SNI, and certificate verification.

  Defaults are 32 KiB for cumulative response headers, 64 KiB for the retained
  body, five seconds for connection setup, and 15 seconds for the complete
  operation. The operation deadline includes DNS, connection, send, and reads.
  Options may override those limits.

  Body limits apply to Content-Length, chunked, and read-to-close responses.
  Collection stops at the cap and closes the connection without draining the
  remainder. Before the cap is reached, an early close in a Content-Length or
  chunked response returns `{:error, :truncated_body}`. Read-to-close framing
  ends normally when the peer closes.

  TLS uses the OTP CA store unless `cacerts: der_list` supplies a private CA
  bundle through the adapter options or worker's `http_opts`. Literal HTTPS IP
  addresses must also match the certificate's IP subject alternative name.
  See `AshHooks.Http.Httpc` for the alternative adapter's buffering limitations.

  Optional `certificate_pin` adds a leaf identity constraint after normal TLS
  verification and before any HTTP bytes are sent: `{:certificate, der}`,
  `{:sha256, digest}`, or `{:spki_sha256, digest}`. SHA-256 digests are 32 raw
  bytes; the SPKI digest covers DER SubjectPublicKeyInfo. `nil` is off (default).
  A pin never replaces CA, hostname, or IP-SAN checks. Invalid pins and non-HTTPS
  pin use fail closed; a mismatch returns `{:error, :certificate_pin_mismatch}`.
  The delivery runtime records these as non-retryable failures.
  """

  @behaviour AshHooks.Http

  alias AshHooks.Http.{Engine, Request}

  @doc """
  Sends one request with an atom or case-insensitive method string, URL,
  binary header map, and binary body (`nil` means empty).

  Options are `:timeout` (15,000 ms for the whole operation),
  `:connect_timeout` (5,000 ms), `:max_body_bytes` (65,536 retained bytes),
  and `:cacerts` (DER certificates; defaults to the OTP CA store).
  `validate_destination: false` bypasses public-address validation and is
  intended only for controlled tests; keep validation enabled for untrusted URLs.

  Additional options are `:max_header_bytes` (32,768),
  `:max_interim_responses` (8), and `:certificate_pin` (default `nil`), using
  the pin formats in the module contract. Response collection stops at its cap.

  Returns `{:ok, %{status: status, headers: header_pairs, body: bytes}}` or
  `{:error, reason}` for invalid input, destination refusal, TLS, transport,
  timeout, or response framing failures. Redirects are returned without following.
  """
  @impl true
  @spec request(atom(), String.t(), map(), binary() | nil, keyword()) ::
          {:ok, %{status: integer(), headers: list(), body: binary() | nil}}
          | {:error, term()}
  def request(method, url, headers, body, opts \\ []) do
    method
    |> Engine.request(url, headers, body, state(opts))
    |> result()
  end

  @doc "Sends every prepared request line verbatim, with bounded response collection."
  @impl true
  def send_prepared(%Request{} = request, opts) do
    request
    |> Engine.prepared(state(opts))
    |> result()
  end

  defp state(opts) do
    opts
    |> Keyword.update(:max_body_bytes, 65_536, &(&1 || 65_536))
    |> Keyword.put(:idle_timeout, opts[:timeout] || 15_000)
    |> Keyword.put(:capture_limit, true)
    |> Engine.init()
  end

  defp result({:ok, state}) do
    {:ok,
     %{
       status: state.status,
       headers: state.headers,
       body: state.body |> Enum.reverse() |> IO.iodata_to_binary()
     }}
  end

  defp result({:error, reason, _state}) when reason in [:deadline_exceeded, :idle_timeout],
    do: {:error, :timeout}

  defp result({:error, reason, _state}), do: {:error, reason}
end
