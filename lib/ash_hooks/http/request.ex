defmodule AshHooks.Http.Request do
  @moduledoc """
  A complete HTTP/1.1 request prepared before host signing.

  `target` preserves the URL's escaped path and query, with `/` for an empty
  path. `headers` contains every line in wire order, including authority,
  framing, content type and connection close. An adapter implementing
  `send_prepared/2` must send these values unchanged, adding no header lines.
  """

  alias AshHooks.Http.{Headers, Target}

  @enforce_keys [:method, :url, :target, :headers, :body]
  @derive {Inspect, except: [:headers, :body]}
  defstruct [:method, :url, :target, :headers, :body]

  @type t :: %__MODULE__{
          method: String.t(),
          url: String.t(),
          target: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @methods ~w(CONNECT DELETE GET HEAD OPTIONS PATCH POST PUT TRACE)

  @doc "Builds the complete ordered request without resolving its destination."
  @spec new(atom() | String.t(), String.t(), map(), binary()) :: {:ok, t()} | {:error, atom()}
  def new(method, url, headers, body) when is_map(headers) and is_binary(body) do
    with {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
         {:ok, lines} <-
           Headers.validate_ordered(
             [
               {"host", Target.host_header(String.downcase(uri.host), uri.port, uri.scheme)},
               {"connection", "close"},
               {"content-length", Integer.to_string(byte_size(body))}
             ] ++ Map.to_list(Map.put_new(headers, "content-type", "application/json"))
           ) do
      request = %__MODULE__{
        method: method |> to_string() |> String.upcase(),
        url: url,
        target: target(uri),
        headers: lines,
        body: body
      }

      with :ok <- validate(request), do: {:ok, request}
    else
      _ -> {:error, :invalid_prepared_request}
    end
  rescue
    _ -> {:error, :invalid_prepared_request}
  end

  def new(_, _, _, _), do: {:error, :invalid_prepared_request}

  @doc false
  def target(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if is_nil(uri.query), do: path, else: path <> "?" <> uri.query
  end

  @doc false
  def validate(%__MODULE__{} = request) do
    with true <- request.method in @methods and is_binary(request.body),
         {:ok, uri} <- URI.new(request.url),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
         true <- request.target == target(uri),
         true <- Enum.all?(:binary.bin_to_list(request.target), &(&1 in 33..126)),
         {:ok, lines} <- Headers.validate_ordered(request.headers),
         headers = Map.new(lines, fn {name, value} -> {String.downcase(name, :ascii), value} end),
         true <-
           headers["host"] == Target.host_header(String.downcase(uri.host), uri.port, uri.scheme),
         true <- headers["content-length"] == Integer.to_string(byte_size(request.body)),
         true <- headers["connection"] == "close",
         true <- Map.has_key?(headers, "content-type"),
         false <-
           Enum.any?(
             ~w(transfer-encoding te trailer upgrade proxy-connection keep-alive),
             &Map.has_key?(headers, &1)
           ) do
      :ok
    else
      _ -> {:error, :invalid_prepared_request}
    end
  rescue
    _ -> {:error, :invalid_prepared_request}
  end
end
