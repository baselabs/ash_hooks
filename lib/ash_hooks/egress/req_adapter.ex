if Code.ensure_loaded?(Req.Request) do
  defmodule AshHooks.Egress.ReqAdapter do
    @moduledoc """
    An optional Req 0.7 adapter using the pinned egress engine.

    Store the enrolled `AshHooks.Egress.Destination` in request private data
    under `:ash_hooks_destination`, and optional `AshHooks.Egress` options
    under `:ash_hooks_egress_options`, using `Req.Request.put_private/3`.
    Set `redirect: false` and either `retry: false` or `max_retries: 0`.
    An installed retry function, including ReqLLM's, is accepted with zero
    effective retries. Any `:follow_redirects` option is refused, even false.

    Callback and collectable `into:` values stream in the caller. Callback
    functions receive `{:data, bytes}` with `{request, response}`, as in Req.
    Collectables receive the body for status 200; other statuses accumulate a
    binary, following Req's contract. Request bodies are materialized from
    iodata or enumerable chunks before I/O. Async `into: :self` is unsupported.
    No Finch pool or Finch callback is invoked.

    The adapter's private attempt latch is returned on the request, including
    requests returned by callbacks. Req's retry count also prevents a second
    adapter run. Req-based clients use the adapter; other client transports
    can call `AshHooks.Egress.stream/8` directly.
    """

    alias AshHooks.Egress
    alias AshHooks.Egress.Error

    @latch :ash_hooks_egress_attempted

    @doc """
    Runs one Req adapter attempt, returning `{request, response_or_exception}`.

    Returned requests retain this adapter, disabled redirects and retries, and an attempt latch,
    including refusals before I/O. Transport failures are
    `AshHooks.Egress.Error` exceptions. Successful responses store egress
    completion in response private data under `:ash_hooks_completion`.
    A returned request cannot be run again through this adapter.
    """
    @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Error.t()}
    def run(request) do
      refusal = refusal(request)
      request = attempted(request)

      if refusal do
        refuse(request, refusal)
      else
        dispatch(request)
      end
    end

    defp attempted(request) do
      %{request | adapter: __MODULE__}
      |> Req.Request.put_private(@latch, true)
      |> Req.Request.put_option(:retry, false)
      |> Req.Request.put_option(:redirect, false)
      |> Req.Request.delete_option(:follow_redirects)
    end

    defp refuse(request, reason) do
      destination = Req.Request.get_private(request, :ash_hooks_destination)
      opts = Req.Request.get_private(request, :ash_hooks_egress_options, [])

      {:error, error} =
        Egress.request(
          destination,
          request.method,
          URI.to_string(request.url),
          %{},
          nil,
          Keyword.put(opts, :refusal, reason)
        )

      Req.Request.halt(request, error)
    end

    defp refusal(request) do
      cond do
        Req.Request.get_private(request, :req_retry_count, 0) > 0 or
            Req.Request.get_private(request, @latch, false) ->
          :repeat_attempt_refused

        not retry_disabled?(request.options) ->
          :retry_not_disabled

        Map.get(request.options, :redirect, true) ||
            Map.has_key?(request.options, :follow_redirects) ->
          :redirect_refused

        request.into in [:self, :legacy_self] ->
          :invalid_request

        true ->
          nil
      end
    end

    defp retry_disabled?(options) do
      case Map.get(options, :retry, :safe_transient) do
        false ->
          true

        retry when retry in [:safe_transient, :transient, :safe, :never] ->
          Map.get(options, :max_retries, 3) === 0

        fun when is_function(fun, 1) or is_function(fun, 2) ->
          Map.get(options, :max_retries, 3) === 0

        _ ->
          false
      end
    end

    defp dispatch(request) do
      destination = Req.Request.get_private(request, :ash_hooks_destination)
      opts = Req.Request.get_private(request, :ash_hooks_egress_options, [])
      url = URI.to_string(request.url)

      headers =
        Enum.flat_map(request.headers, fn {name, values} ->
          Enum.map(values, &{name, &1})
        end)

      case body(request.body) do
        {:ok, body} ->
          send_request(request, destination, url, headers, body, opts)

        :error ->
          refuse(request, :invalid_request)
      end
    end

    defp body(nil), do: {:ok, ""}

    defp body(body) do
      chunks = if Enumerable.impl_for(body), do: Enum.to_list(body), else: body
      {:ok, IO.iodata_to_binary(chunks)}
    catch
      _, _ -> :error
    end

    defp send_request(%{into: nil} = request, destination, url, headers, body, opts) do
      case Egress.request(destination, request.method, url, headers, body, opts) do
        {:ok, response} ->
          result =
            Req.Response.new(
              status: response.status,
              headers: response.headers,
              body: response.body
            )

          {request, completion(result, response.completion)}

        {:error, error} ->
          {request, error}
      end
    end

    defp send_request(%{into: fun} = request, destination, url, headers, body, opts)
         when is_function(fun, 2) do
      callback = fn
        {:status, status}, {req, resp} ->
          {:cont, {req, %{resp | status: status}}}

        {:headers, fields}, {req, resp} ->
          {:cont, {req, %{resp | headers: Req.Response.new(headers: fields).headers}}}

        {:data, data}, acc ->
          case fun.({:data, data}, acc) do
            {action, {%Req.Request{}, %Req.Response{}}} = result when action in [:cont, :halt] ->
              result

            _ ->
              :invalid_callback_result
          end
      end

      case Egress.stream(
             destination,
             request.method,
             url,
             headers,
             body,
             callback,
             {request, Req.Response.new()},
             opts
           ) do
        {:ok, response} ->
          {req, resp} = response.acc
          {attempted(req), completion(resp, response.completion)}

        {:error, error} ->
          {request, error}
      end
    end

    defp send_request(request, destination, url, headers, body, opts) do
      key = {__MODULE__, make_ref()}
      callback = collector_callback(request, key)

      finalize = fn _, {req, resp} ->
        {value, collector} = Process.get(key)
        body = collector.(value, :done)
        Process.delete(key)
        {:cont, {req, %{resp | body: body}}}
      end

      try do
        case Egress.stream(
               destination,
               request.method,
               url,
               headers,
               body,
               callback,
               {request, Req.Response.new()},
               Keyword.put(opts, :on_complete, finalize)
             ) do
          {:ok, response} ->
            {req, resp} = response.acc
            {req, completion(resp, response.completion)}

          {:error, error} ->
            {request, error}
        end
      after
        if entry = Process.delete(key) do
          {acc, collector} = entry
          halt_collector(collector, acc)
        end
      end
    end

    defp collector_callback(request, key) do
      fn
        {:status, status}, {req, resp} ->
          collectable = if status == 200, do: request.into, else: ""
          Process.put(key, Collectable.into(collectable))
          {:cont, {req, %{resp | status: status}}}

        {:headers, fields}, {req, resp} ->
          {:cont, {req, %{resp | headers: Req.Response.new(headers: fields).headers}}}

        {:data, data}, acc ->
          {value, collector} = Process.get(key)
          Process.put(key, {collector.(value, {:cont, data}), collector})
          {:cont, acc}
      end
    end

    defp halt_collector(collector, acc) do
      collector.(acc, :halt)
    catch
      _, _ -> :ok
    end

    defp completion(response, value),
      do: Req.Response.put_private(response, :ash_hooks_completion, value)
  end
end
