if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshHooks.Plug do
    @moduledoc """
    Optional Plug adapter for the synchronous inbound webhook pipeline.

    Resolves a source, captures exact raw request bytes, consults the provider's
    optional handshake, checks the method, and calls `AshHooks.Ingress.ingest/4`
    once. Every answer is sent and the connection halted. Plug must be installed
    by the host; this module is absent when Plug is unavailable.

    Configure `AshHooks.BodyReader` on the endpoint's `Plug.Parsers`, then
    `forward` a webhook route to this plug from the router, outside
    browser/session/CSRF pipelines: with `:source` for a fixed source on a
    single-tenant ledger, or with `:resolve` for a scoped or multitenant one. The
    README's [Mounting the plug](README.md#mounting-the-plug)
    section shows both in a Phoenix endpoint and router; the test suite compiles
    and runs those examples as written.

    `:resolve` is called with the conn followed by its configured arguments.
    It must return `{:ok, %{source: atom}}`, optionally including `:tenant`,
    `:scope`, and `:connection` for ingress, and `:signature_header`, which
    overrides the plug option of that name for the resolved source. Look up stored endpoint records;
    never trust a path string as a module or tenant. `{:error, :not_found}`
    answers 404 and `{:error, :unavailable}` answers 503, with no ledger write.

    Options (validated by `init/1` without resource introspection):

      * `:resource`: required ledger module carrying `AshHooks.InboundDelivery`.
      * Exactly one of `:source` (inbound name atom for a fixed single-tenant
        route) or `:resolve` (`{module, function, args}`).
      * `:request_uri`: `nil` (default, no URI in ctx), a public base URL
        string, or an MFA called with the conn to return the full public URI.
        A base has trailing slashes trimmed and the original request path and
        query appended. The conn's host, scheme and port are never used.
      * `:methods`: uppercase HTTP method strings, default `["POST"]`.
        A provider handshake is consulted before a 405 refusal with `allow`.
      * `:length`: positive total body limit, default 8,000,000 bytes;
        `:read_length`: positive socket read size, default 1,000,000 bytes;
        `:read_timeout`: socket read timeout, default 15,000 milliseconds.
        These apply only to reads made by this plug. Configure preceding
        parsers' limits separately.
      * `:respond`: optional MFA called with the exact ingest outcome,
        returning `{status, headers, body}` or `:default`.
      * `:refuse`: optional MFA called with `:not_found`, `:unavailable`,
        `:method_not_allowed`, `:too_large`, or `:body_consumed`, returning
        `{headers, body}` or `:default`. Status stays fixed. Required `allow`
        and `retry-after` headers win over conflicting host headers.
      * `:retry_after`: positive seconds, default 60, for `retry-after` on
        resolver unavailability and every 503 from `default_response/2`.
      * `:signature_header`: lowercase request header name, default `nil`.
        Its value becomes `ctx.signature` for providers whose
        `signature_source/0` is `:header`, the default for a provider written
        directly against `AshHooks.Provider`. A request with no such header,
        or with more than one line of it, carries no signature and is refused
        as unsigned (400). With `ingress_tracking :on`, ingress may store a
        rejection row.

    All MFAs receive their configured arguments after the request/outcome/reason.
    Response headers use lowercase names, as required by Plug.

    Cached bytes from `AshHooks.BodyReader.raw_body/1` take priority. A host's
    own endpoint reader can supply the complete exact bytes through
    `AshHooks.BodyReader.put_raw_body/2`, without a second read. Otherwise the
    plug reads and accumulates chunks up to `:length` (413 on overflow). An
    empty read with a positive declared content-length means a parser consumed
    the body without `AshHooks.BodyReader`: answer 500, log the configuration
    fix once, and write nothing. Parsed params are never re-encoded.

    `AshHooks.Provider.handshake/2` dispatches a provider's optional
    `handshake/1` before method and signature checks. A handshake response writes
    nothing. After ingest, response precedence is provider `response/1`, then
    `:respond`, then `default_response/2`; `:default` falls through each policy.
    Those policies do not receive refusals. Custom provider or host 503s own
    their headers and are not amended with `:retry_after`.

    Configured providers (`use AshHooks.Provider, verify: [...]`) extract their
    signature from request headers or the body and need no `:signature_header`.
    A provider whose signature source is `:header` reads only `ctx.signature`;
    name its header with `:signature_header`, here or from the resolver.
    `AshHooks.Ingress.ingest/4` remains available for lower-level composition.
    """

    @behaviour Plug
    require Logger

    alias AshHooks.{BodyReader, Info, Ingress, Provider}
    alias AshHooks.Errors.Invalid.{InvalidSignature, MalformedPayload, StaleTimestamp}
    alias Plug.Conn.Query

    @mfa {:tuple, [:atom, :atom, {:list, :any}]}
    @options [
      resource: [type: :atom, required: true],
      source: [type: :atom],
      resolve: [type: @mfa],
      request_uri: [type: {:or, [nil, :string, @mfa]}, default: nil],
      methods: [type: {:list, {:custom, __MODULE__, :validate_method, []}}, default: ["POST"]],
      length: [type: :pos_integer, default: 8_000_000],
      read_length: [type: :pos_integer, default: 1_000_000],
      read_timeout: [type: :timeout, default: 15_000],
      respond: [type: @mfa],
      refuse: [type: @mfa],
      retry_after: [type: :pos_integer, default: 60],
      signature_header: [type: {:or, [nil, {:custom, __MODULE__, :validate_header, []}]}]
    ]
    @refusal_statuses %{
      not_found: 404,
      unavailable: 503,
      method_not_allowed: 405,
      too_large: 413,
      body_consumed: 500
    }

    @impl true
    def init(options) do
      options = Spark.Options.validate!(options, @options)

      if Keyword.has_key?(options, :source) == Keyword.has_key?(options, :resolve) do
        raise ArgumentError, "expected exactly one of :source or :resolve"
      end

      options
    end

    @doc false
    def validate_method(method) do
      if is_binary(method) and Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Z]+\z/, method),
        do: {:ok, method},
        else: {:error, "expected an uppercase HTTP method string"}
    end

    @doc false
    def validate_header(name) do
      if is_binary(name) and Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9a-z]+\z/, name),
        do: {:ok, name},
        else: {:error, "expected a lowercase HTTP header name string"}
    end

    @impl true
    def call(conn, options) do
      case resolve(conn, options) do
        {:ok, context} ->
          case raw_body(conn, options) do
            {:ok, raw, conn} -> deliver(conn, raw, context, options)
            {:error, reason, conn} -> refuse(conn, reason, options)
          end

        {:error, reason} ->
          refuse(conn, reason, options)
      end
    end

    @doc """
    Maps an ingest outcome to `{status, headers, body}` using validated plug
    options returned by `init/1`. A host `:respond` policy may call this function
    explicitly with the same options.

    Terminal rows (`:processed`, `:failed_permanent`, `:superseded`) get 200;
    other successful ledger outcomes get 500 so the sender retries. Typed
    invalid-signature, stale-timestamp and malformed-payload errors get 400.
    Everything else gets 503 with `retry-after` from `options[:retry_after]`.
    All default bodies are empty. Custom policies' responses are never amended.
    """
    @spec default_response(Provider.ingest_outcome(), keyword()) :: Provider.http_response()
    def default_response(outcome, options) do
      case outcome do
        {:ok, _, %{status: status}} when status in [:processed, :failed_permanent, :superseded] ->
          {200, [], ""}

        {:ok, _, _} ->
          {500, [], ""}

        {:error, %error{}} when error in [InvalidSignature, StaleTimestamp, MalformedPayload] ->
          {400, [], ""}

        _ ->
          {503, retry_header(options), ""}
      end
    end

    defp resolve(conn, options) do
      case options[:resolve] do
        nil -> {:ok, %{source: options[:source]}}
        {module, function, args} -> apply(module, function, [conn | args])
      end
    end

    defp deliver(conn, raw, context, options) do
      provider =
        case Info.inbound(options[:resource], context.source) do
          nil -> nil
          inbound -> inbound.provider
        end

      request = %{
        method: conn.method,
        query_params: Query.decode(conn.query_string),
        headers: conn.req_headers,
        raw_body: raw
      }

      case Provider.handshake(provider, request) do
        {:respond, status, headers, body} ->
          answer(conn, {status, headers, body})

        :deliver ->
          if conn.method in options[:methods] do
            ingest(conn, raw, context, provider, options)
          else
            refuse(conn, :method_not_allowed, options)
          end
      end
    end

    defp ingest(conn, raw, context, provider, options) do
      ctx =
        context
        |> Map.take([:tenant, :scope, :connection])
        |> Map.merge(%{headers: conn.req_headers, method: conn.method})
        |> signature(conn, Map.get(context, :signature_header, options[:signature_header]))
        |> request_uri(conn, options[:request_uri])

      outcome = Ingress.ingest(options[:resource], context.source, raw, ctx)

      response =
        case Provider.response(provider, outcome) do
          :default ->
            case invoke(options[:respond], outcome) do
              :default -> default_response(outcome, options)
              response -> response
            end

          response ->
            response
        end

      answer(conn, response)
    end

    # Exactly one header line carries the signature; none or several leave
    # ctx.signature unset, so ingress refuses the delivery as unsigned.
    defp signature(ctx, _conn, nil), do: ctx

    defp signature(ctx, conn, name) do
      case Plug.Conn.get_req_header(conn, name) do
        [value] -> Map.put(ctx, :signature, value)
        _ -> ctx
      end
    end

    defp request_uri(ctx, _conn, nil), do: ctx

    defp request_uri(ctx, conn, {module, function, args}),
      do: Map.put(ctx, :request_uri, apply(module, function, [conn | args]))

    defp request_uri(ctx, conn, base) do
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
      Map.put(ctx, :request_uri, String.trim_trailing(base, "/") <> conn.request_path <> query)
    end

    defp raw_body(conn, options) do
      case BodyReader.raw_body(conn) do
        nil -> read_body(conn, options, [], 0)
        raw -> {:ok, raw, conn}
      end
    end

    defp read_body(conn, options, chunks, size) do
      read_options = [
        length: min(options[:length], options[:read_length]),
        read_length: options[:read_length],
        read_timeout: options[:read_timeout]
      ]

      case Plug.Conn.read_body(conn, read_options) do
        {tag, chunk, conn} when tag in [:ok, :more] ->
          size = size + byte_size(chunk)

          cond do
            size > options[:length] -> {:error, :too_large, conn}
            tag == :more -> read_body(conn, options, [chunk | chunks], size)
            true -> check_consumed(conn, IO.iodata_to_binary(Enum.reverse([chunk | chunks])))
          end

        {:error, _reason} ->
          {:error, :unavailable, conn}
      end
    end

    defp check_consumed(conn, raw) do
      if raw == "" and positive_content_length?(conn) do
        Logger.error(
          "AshHooks.Plug: request body already consumed; configure " <>
            "body_reader: {AshHooks.BodyReader, :read_body, []} on Plug.Parsers"
        )

        {:error, :body_consumed, conn}
      else
        {:ok, raw, conn}
      end
    end

    defp positive_content_length?(conn) do
      Enum.any?(Plug.Conn.get_req_header(conn, "content-length"), fn value ->
        case Integer.parse(value) do
          {length, ""} when length > 0 -> true
          _ -> false
        end
      end)
    end

    defp refuse(conn, reason, options) do
      {headers, body} =
        case invoke(options[:refuse], reason) do
          :default -> {[], ""}
          response -> response
        end

      required =
        case reason do
          :method_not_allowed -> [{"allow", Enum.join(options[:methods], ", ")}]
          :unavailable -> retry_header(options)
          _ -> []
        end

      conn
      |> Plug.Conn.merge_resp_headers(headers)
      |> answer({Map.fetch!(@refusal_statuses, reason), required, body})
    end

    defp retry_header(options), do: [{"retry-after", Integer.to_string(options[:retry_after])}]

    defp invoke(nil, _value), do: :default
    defp invoke({module, function, args}, value), do: apply(module, function, [value | args])

    defp answer(conn, {status, headers, body}) do
      conn
      |> Plug.Conn.merge_resp_headers(headers)
      |> Plug.Conn.send_resp(status, body)
      |> Plug.Conn.halt()
    end
  end
end
