# Plug is an optional dependency; the guard keeps the package compiling
# where it is absent (ADR-0004). When the consumer's environment has Plug,
# the module is defined and the installer's endpoint codemod wires it in.
if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshHooks.BodyReader do
    @moduledoc """
    Endpoint `body_reader` that caches the raw, pre-parser request bytes for
    signature verification.

    Configure it as the `body_reader` of the endpoint's `Plug.Parsers`,
    `{AshHooks.BodyReader, :read_body, []}` (the installer patches this; a router
    plug cannot recover pre-parse bytes). The README's
    [Receive with AshHooks.Plug](README.md#3-receive-with-ashhooksplug) section
    shows the endpoint and router; the test suite compiles and runs that example
    as written.

    `AshHooks.Plug` retrieves the cached bytes through `raw_body/1` automatically.
    Custom pipelines may pass `raw_body(conn)` to `AshHooks.Ingress.ingest/4`.
    Signature schemes sign over the exact wire bytes, so any re-encoding
    (parsed params, JSON roundtrip) would break verification. Without a preceding
    parser, `AshHooks.Plug` can read the request body itself.

    The reader is endpoint-wide by default: every parsed request (not only
    webhook routes) carries a second copy of its body in the connection cache for
    the request lifetime, bounded by the parser's `:length`. To scope the
    memory cost to the webhook routes, pass `:only` path prefixes as the
    reader's arguments, `{AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]}`.
    Only requests whose path starts with one of the prefixes are cached;
    everything else passes through with zero retained bytes.

    A host with its own endpoint reader does not need a second reader. Call
    `put_raw_body/2` from that reader (configured as `Plug.Parsers`' `body_reader`),
    or before parsing, with the complete body exactly as sent. Never supply a
    partial body or reconstruct bytes from parsed params. The storage key is an
    implementation detail; use `put_raw_body/2` and `raw_body/1` to exchange bytes.
    """

    @raw_body_key :ash_hooks_raw_body

    @doc """
    Stores the complete, exact request body for signature verification.

    Call this from a host's own `Plug.Parsers` `body_reader`, or before parsing,
    with the whole body as sent. Never supply a partial or re-encoded body.
    Returns the updated connection. Raises `ArgumentError` unless `bytes` is a
    binary; an empty binary is a valid body.
    """
    @spec put_raw_body(Plug.Conn.t(), binary()) :: Plug.Conn.t()
    def put_raw_body(conn, bytes) when is_binary(bytes),
      do: Plug.Conn.put_private(conn, @raw_body_key, bytes)

    def put_raw_body(_conn, _bytes), do: raise(ArgumentError, "raw body must be a binary")

    @doc """
    Returns the stored exact request bytes, or `nil` when none have been stored.

    Use after the endpoint body reader has completed, or after a host has stored
    the complete body with `put_raw_body/2`. The connection storage key is private.
    """
    @spec raw_body(Plug.Conn.t()) :: binary() | nil
    def raw_body(conn), do: conn.private[@raw_body_key]

    @doc """
    `body_reader` entry point. `Plug.Parsers` invokes the configured MFA as
    `apply(mod, fun, [conn, opts | extra_args])` — extras arrive as a THIRD
    positional argument, so the arity-3 clause is the one the parser calls;
    `opts` and `extra` merge.
    """
    @spec read_body(Plug.Conn.t(), keyword(), keyword() | {atom(), term()}) ::
            {:ok, binary(), Plug.Conn.t()}
            | {:more, binary(), Plug.Conn.t()}
            | {:error, term()}
    def read_body(conn, opts, extra \\ []) do
      # the parser spreads the MFA's arg list positionally, so ONE keyword
      # option arrives as a bare tuple ({:only, [...]}) and a nested list
      # ([[only: ...]]) as a list — List.wrap normalizes both
      opts = Keyword.merge(opts, List.wrap(extra))

      if caching?(conn, opts) do
        cache_read(conn, opts)
      else
        Plug.Conn.read_body(conn, opts)
      end
    end

    defp cache_read(conn, opts) do
      case Plug.Conn.read_body(conn, opts) do
        {:ok, chunk, conn} ->
          {:ok, chunk, cache(conn, chunk)}

        {:more, chunk, conn} ->
          # large bodies arrive in chunks — accumulate, or the cache would
          # hold only the final chunk
          {:more, chunk, cache(conn, chunk)}

        {:error, _reason} = error ->
          error
      end
    end

    # Matching keys on the ROUTER-COLLAPSED path (`conn.path_info`), not the
    # raw request path: a routable non-canonical path like `//webhooks/x`
    # reaches the webhook action with path_info ["webhooks", "x"], and the
    # raw-path form would silently skip caching (the delivery then fails
    # closed as "no raw body"). `only: []` behaves as unset (cache
    # everything) rather than disabling caching everywhere.
    defp caching?(conn, opts) do
      case Keyword.get(opts, :only) do
        prefixes when prefixes in [nil, []] -> true
        prefixes -> prefix_match?(canonical_path(conn), List.wrap(prefixes))
      end
    end

    defp canonical_path(conn), do: "/" <> Enum.join(conn.path_info, "/")

    defp prefix_match?(canonical, prefixes) do
      Enum.any?(prefixes, fn prefix ->
        prefix = if String.starts_with?(prefix, "/"), do: prefix, else: "/" <> prefix
        String.starts_with?(canonical, prefix)
      end)
    end

    defp cache(conn, chunk) do
      put_raw_body(conn, (raw_body(conn) || <<>>) <> chunk)
    end
  end
end
