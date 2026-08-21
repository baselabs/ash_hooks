# Plug is an optional dependency; the guard keeps the package compiling
# where it is absent (ADR-0004). When the consumer's environment has Plug,
# the module is defined and the installer's endpoint codemod wires it in.
if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshHooks.BodyReader do
    @moduledoc """
    Endpoint `body_reader` that caches the raw, pre-parser request bytes for
    signature verification.

    Configure it on the endpoint's `Plug.Parsers` (the installer patches
    this; a router plug CANNOT recover pre-parse bytes):

        plug Plug.Parsers,
          ...,
          body_reader: {AshHooks.BodyReader, :read_body, []}

    The controller then passes `conn.private[:ash_hooks_raw_body]` to
    `AshHooks.Ingress.ingest/4` — signature schemes sign over the exact wire
    bytes, so any re-encoding (parsed params, JSON roundtrip) would break
    verification.

    The reader is endpoint-wide by default: every parsed request (not only
    webhook routes) carries a second copy of its body in `conn.private` for
    the request lifetime, bounded by the parser's `:length`. To scope the
    memory cost to the webhook routes, pass `:only` path prefixes:

        plug Plug.Parsers,
          ...,
          body_reader: {AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]}

    Only requests whose path starts with one of the prefixes are cached;
    everything else passes through with zero retained bytes.
    """

    @raw_body_key :ash_hooks_raw_body

    @spec read_body(Plug.Conn.t(), keyword()) ::
            {:ok, binary(), Plug.Conn.t()}
            | {:more, binary(), Plug.Conn.t()}
            | {:error, term()}
    def read_body(conn, opts) do
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

    defp caching?(conn, opts) do
      case Keyword.get(opts, :only) do
        nil -> true
        prefixes -> Enum.any?(List.wrap(prefixes), &String.starts_with?(conn.request_path, &1))
      end
    end

    defp cache(conn, chunk) do
      Plug.Conn.put_private(conn, @raw_body_key, accumulated(conn) <> chunk)
    end

    defp accumulated(conn), do: conn.private[@raw_body_key] || <<>>
  end
end
