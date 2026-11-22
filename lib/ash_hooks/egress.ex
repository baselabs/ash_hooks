defmodule AshHooks.Egress do
  @moduledoc """
  One pinned HTTP/1.1 attempt, buffered or streamed, with explicit outcomes.

  Enroll destinations with `destination/2` and persist their plain data on
  host-owned records. Every attempt checks its effective URL against that
  enrollment, resolves once, and connects to a validated address. The original
  host remains the HTTP authority and TLS identity. No redirect or retry is
  performed. HTTP/2, proxies, and connection reuse are unsupported.

  `AshHooks.Egress.Error` distinguishes an unsent request from one that may
  have left. The host owns admission, credential binding, committed intent,
  destination selection, and recovery when a process or node returns nothing.
  See the [pinned egress guide](pinned-egress.html) for Req and ReqLLM composition.
  """

  alias AshHooks.Egress.{Destination, Error, Response}
  alias AshHooks.Http.{CertificatePin, Engine, Headers, Request}

  @reasons ~w(destination_mismatch unsafe_destination unresolved_host connect_failed
    tls_failed certificate_pin_mismatch cert_ip_mismatch invalid_certificate_pin
    certificate_pin_requires_https unsupported_method invalid_request invalid_options
    invalid_header_name invalid_header_value duplicate_header truncated_response
    truncated_body header_block_too_large malformed_status_line malformed_content_length
    malformed_chunked too_many_interim_responses body_too_large idle_timeout
    deadline_exceeded callback_failed redirect_refused retry_not_disabled
    repeat_attempt_refused unsupported_upgrade transport_failed)a

  @doc """
  Enrolls an HTTPS URL without DNS resolution.

  Returns `{:ok, destination}` or `{:error, %AshHooks.Egress.Error{}}`.
  Options are `:destination_id` (opaque telemetry identifier), `:path_prefix`
  (defaults to the URL's path, or `/`), and `:certificate_pin` (the formats
  documented by `AshHooks.Http.Bounded`). Userinfo and fragments are refused.
  The explicit port is stored even when omitted from the URL.

  `allow_http: true` permits HTTP for controlled tests. Loopback fixtures also
  require `validate_destination: false`; that enrollment flag is preserved
  across sends and cannot be overridden by per-request options. Production
  enrollment uses `AshHooks.Ssrf.registration_safe?/1` and send-time public
  address validation. Hosts must protect their stored enrollment data.
  """
  @spec destination(String.t(), keyword()) :: {:ok, Destination.t()} | {:error, Error.t()}
  def destination(url, opts \\ []) do
    with {:ok, uri} <- uri(url),
         true <- uri.scheme == "https" or (uri.scheme == "http" and opts[:allow_http] == true),
         true <- opts[:validate_destination] == false or AshHooks.Ssrf.registration_safe?(url),
         prefix = Keyword.get(opts, :path_prefix, uri.path || "/"),
         true <- valid_path?(prefix),
         :ok <- CertificatePin.validate(opts[:certificate_pin], uri.scheme) do
      {:ok,
       %Destination{
         scheme: uri.scheme,
         host: String.downcase(uri.host),
         port: uri.port,
         path_prefix: prefix,
         certificate_pin: opts[:certificate_pin],
         id: opts[:destination_id],
         allow_http: opts[:allow_http] == true,
         validate_destination: opts[:validate_destination] != false
       }}
    else
      {:error, reason} -> {:error, error(reason, Engine.init([]))}
      _ -> {:error, error(:unsafe_destination, Engine.init([]))}
    end
  end

  @doc """
  Sends one buffered request to a destination URL or absolute path and query.

  Returns `{:ok, %AshHooks.Egress.Response{}}` or
  `{:error, %AshHooks.Egress.Error{}}`. Headers are binary name/value pairs
  in a map or list; the body is a binary or `nil`. Authority, connection, and
  length headers are transport-owned and cannot be supplied.

  Options: `:timeout` (15,000 ms from call start), `:connect_timeout`
  (5,000 ms from call start, including DNS and TLS), `:idle_timeout`
  (15,000 ms between reads, including callback time), `:max_header_bytes`
  (32,768 cumulative bytes), `:max_interim_responses` (8), `:cacerts`
  (DER trust bundle, default OTP store), and `:max_body_bytes` (65,536).
  Exceeding the body cap returns `:body_too_large`. Explicit
  `capture_limit: true` instead returns the retained prefix with completion
  `:capture_limit`; it does not establish remote completion.
  """
  @spec request(
          Destination.t(),
          atom() | String.t(),
          String.t(),
          map() | list(),
          binary() | nil,
          keyword()
        ) :: {:ok, Response.t()} | {:error, Error.t()}
  def request(destination, method, url, headers, body, opts \\ []) do
    perform(
      destination,
      method,
      url,
      headers,
      body,
      nil,
      nil,
      Keyword.put_new(opts, :max_body_bytes, 65_536)
    )
  end

  @doc """
  Streams one response through `fun.(event, acc)` in the calling process.

  Events are `{:status, integer}`, `{:headers, pairs}`, and `{:data, binary}`.
  Return `{:cont, acc}` or `{:halt, acc}`. Success is `{:ok, response}` with
  `response.body == nil` and the final accumulator in `response.acc`.
  Halt closes the socket and sets completion `:halted`. A raise, throw, exit,
  or invalid callback result closes it and returns `:callback_failed` without
  retaining the raised term. Caller death closes its socket.

  Options match `request/6`, except there is no default body cap. An explicit
  `:max_body_bytes` applies to cumulative decoded body bytes. There is no
  background reader and no retry. Any 3xx is refused before callbacks run;
  101 returns `:unsupported_upgrade`.
  """
  @spec stream(
          Destination.t(),
          atom() | String.t(),
          String.t(),
          map() | list(),
          binary() | nil,
          function(),
          term(),
          keyword()
        ) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def stream(destination, method, url, headers, body, fun, acc, opts \\ []) do
    perform(destination, method, url, headers, body, fun, acc, opts)
  end

  defp perform(destination, method, url, headers, body, fun, acc, opts) do
    valid_options = valid_options?(opts)
    state = Engine.init(if(valid_options, do: opts, else: []), fun, acc)
    state = %{state | method: telemetry_method(method)}
    emit(:start, destination, state)

    result =
      with true <- valid_options,
           :ok <- refusal(opts[:refusal]),
           {:ok, url} <- effective_url(destination, url),
           :ok <- valid_request(headers, body, fun) do
        engine_opts =
          opts
          |> Keyword.put(:egress, true)
          |> Keyword.put(:validate_destination, destination.validate_destination)
          |> Keyword.put(:certificate_pin, destination.certificate_pin)

        Engine.request(method, url, headers, body, %{state | opts: engine_opts})
      else
        false -> {:error, :invalid_options, state}
        {:error, reason} -> {:error, reason, state}
      end

    finish(result, destination)
  end

  defp refusal(nil), do: :ok
  defp refusal(reason) when reason in @reasons, do: {:error, reason}

  defp valid_options?(opts) do
    Enum.all?(
      [:timeout, :connect_timeout, :idle_timeout, :max_header_bytes, :max_interim_responses],
      fn key ->
        value = Keyword.get(opts, key, 1)
        is_integer(value) and value >= 0
      end
    ) and
      (Keyword.get(opts, :max_body_bytes, :infinity) == :infinity or
         (is_integer(opts[:max_body_bytes]) and opts[:max_body_bytes] >= 0))
  end

  defp valid_request(headers, body, fun) when is_map(headers) or is_list(headers) do
    with true <- is_nil(body) or is_binary(body),
         true <- is_nil(fun) or is_function(fun, 2),
         {:ok, lines} <- Headers.validate_ordered(Enum.to_list(headers)),
         false <-
           Enum.any?(lines, fn {name, _} ->
             String.downcase(name, :ascii) in ~w(host connection content-length transfer-encoding te trailer upgrade
                proxy-connection keep-alive)
           end) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  end

  defp valid_request(_, _, _), do: {:error, :invalid_request}

  defp effective_url(%Destination{} = destination, value) when is_binary(value) do
    base = %URI{
      scheme: destination.scheme,
      host: destination.host,
      port: destination.port,
      path: destination.path_prefix
    }

    url = base |> URI.merge(value) |> URI.to_string()

    with {:ok, uri} <- uri(url),
         true <-
           uri.scheme == destination.scheme and
             String.downcase(uri.host) == destination.host and uri.port == destination.port,
         true <- uri.scheme == "https" or (uri.scheme == "http" and destination.allow_http),
         true <- in_prefix?(uri.path || "/", destination.path_prefix) do
      {:ok, url}
    else
      _ -> {:error, :destination_mismatch}
    end
  rescue
    _ -> {:error, :destination_mismatch}
  end

  defp effective_url(_, _), do: {:error, :destination_mismatch}

  defp uri(url) when is_binary(url) do
    with {:ok, uri} <- URI.new(url),
         true <- is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo),
         true <- is_integer(uri.port) and uri.port in 1..65_535 and is_nil(uri.fragment),
         true <- valid_path?(uri.path || "/"),
         true <- Enum.all?(:binary.bin_to_list(Request.target(uri)), &(&1 in 33..126)) do
      {:ok, uri}
    else
      _ -> {:error, :unsafe_destination}
    end
  end

  defp uri(_), do: {:error, :unsafe_destination}

  defp valid_path?(path) when is_binary(path) do
    decoded = URI.decode(path)

    String.starts_with?(path, "/") and not String.contains?(decoded, "\\") and
      not Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."]))
  end

  defp valid_path?(_), do: false

  defp in_prefix?(path, prefix) do
    path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")
  end

  defp finish({:ok, state}, destination) do
    emit(:stop, destination, state)
    body = if state.callback, do: nil, else: state.body |> Enum.reverse() |> IO.iodata_to_binary()

    {:ok,
     %Response{
       status: state.status,
       headers: state.headers,
       body: body,
       completion: state.completion,
       acc: state.acc
     }}
  end

  defp finish({:error, reason, state}, destination) do
    error = error(reason, state)
    emit(:stop, destination, %{state | reason: error.reason})
    {:error, error}
  end

  defp error(reason, state) do
    reason =
      cond do
        reason == :unsupported_protocol_switch ->
          :unsupported_upgrade

        reason in @reasons ->
          reason

        reason == :timeout and
            System.monotonic_time(:millisecond) >= min(state.deadline, state.connect_deadline) ->
          :deadline_exceeded

        state.phase == :connect ->
          :connect_failed

        state.phase == :tls ->
          :tls_failed

        true ->
          :transport_failed
      end

    %Error{reason: reason, phase: state.phase, sent: state.sent, status: state.status}
  end

  defp emit(event, destination, state) do
    measurements =
      Map.take(state, [
        :dns_duration_ms,
        :connect_duration_ms,
        :tls_duration_ms,
        :first_byte_duration_ms,
        :bytes_sent,
        :bytes_received
      ])
      |> Map.put(:total_duration_ms, System.monotonic_time(:millisecond) - state.started)

    metadata =
      Map.take(state, [:address_family, :method, :phase, :sent, :status, :completion, :reason])
      |> Map.merge(%{
        destination_id: destination_id(destination),
        scheme: scheme(destination),
        port: port(destination)
      })

    :telemetry.execute([:ash_hooks, :egress, event], measurements, metadata)
  end

  defp destination_id(%Destination{id: id}), do: id
  defp destination_id(_), do: nil
  defp scheme(%Destination{scheme: scheme}) when scheme in ["https", "http"], do: scheme
  defp scheme(_), do: nil
  defp port(%Destination{port: port}) when is_integer(port) and port in 1..65_535, do: port
  defp port(_), do: nil

  defp telemetry_method(method) when is_atom(method), do: telemetry_method(Atom.to_string(method))

  defp telemetry_method(method) when is_binary(method) do
    value = String.upcase(method, :ascii)
    if value in ~w(CONNECT DELETE GET HEAD OPTIONS PATCH POST PUT TRACE), do: value
  end

  defp telemetry_method(_), do: nil
end
