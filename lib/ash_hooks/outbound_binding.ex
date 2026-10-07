defmodule AshHooks.OutboundBinding do
  @moduledoc """
  Builds the versioned, opaque identifiers stored in outbound delivery rows.

  Migration code may use `source/3`, `direct_source/2`, and `route/2` to
  backfill the same identifiers that dispatch and worker execution validate.
  Store returned identifiers as-is. They are versioned data descriptors, not
  serialized executable terms. Treat their byte format as opaque.
  """

  @direct_unbound "v1:direct:unbound"
  @route_unbound "v1:route:unbound"
  @route_unkeyed "v1:route:anonymous:unkeyed"

  @doc false
  def direct_unbound_source, do: @direct_unbound
  @doc false
  def unbound_route, do: @route_unbound
  @doc false
  def unkeyed_route, do: @route_unkeyed

  @doc "Returns the source identifier for an outbound declaration and endpoint resource."
  @spec source(module(), atom(), module()) :: String.t()
  def source(emitter, declaration, endpoint_resource) do
    encode([
      "source",
      1,
      module_name(emitter),
      Atom.to_string(declaration),
      module_name(endpoint_resource)
    ])
  end

  @doc "Returns the source identifier for a direct delivery driver configuration."
  @spec direct_source(module(), module()) :: String.t()
  def direct_source(deliveries, endpoints) do
    encode(["direct", 1, module_name(deliveries), module_name(endpoints)])
  end

  @doc false
  def endpoint_resource?(source, endpoint_resource) when is_binary(source) do
    endpoint_name = module_name(endpoint_resource)

    case decode(source) do
      ["source", 1, _emitter, _declaration, ^endpoint_name] -> true
      ["direct", 1, _deliveries, ^endpoint_name] -> true
      _ -> false
    end
  end

  @doc """
  Returns the route identifier for an enqueue callback.

  Named `{module, function}` callbacks and external captures normalize to the
  same identifier. Anonymous callbacks require a stable, nonempty binary (up
  to 512 bytes) or atom `:enqueue_key` for automatic recovery; without it they
  receive an explicit unresolved marker. A nil callback receives the distinct
  unbound marker that reconciliation may bind once to a later named or keyed
  route. Invalid callback and key shapes return an error.
  """
  @spec route(nil | {module(), atom()} | (term(), term() -> term()), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_enqueue_key | :invalid_enqueuer}
  def route(nil, _opts), do: {:ok, @route_unbound}

  def route({module, function}, _opts) when is_atom(module) and is_atom(function),
    do: {:ok, named_route(module, function)}

  def route(callback, opts) when is_function(callback, 2) do
    case Function.info(callback, :type) do
      {:type, :external} ->
        {:module, module} = Function.info(callback, :module)
        {:name, function} = Function.info(callback, :name)
        {:ok, named_route(module, function)}

      _anonymous ->
        keyed_route(opts[:enqueue_key])
    end
  end

  def route(_invalid, _opts), do: {:error, :invalid_enqueuer}

  @doc """
  Returns the route identifier for a named two-argument enqueue callback.

  Use this directly when a migration already stores the callback module and
  function separately. It returns the same identifier as `route/2` receives
  from `{module, function}` or an external function capture.
  """
  @spec named_route(module(), atom()) :: String.t()
  def named_route(module, function) when is_atom(module) and is_atom(function),
    do: encode(["mfa", 1, module_name(module), Atom.to_string(function), 2])

  @doc false
  def recoverable_route?(@route_unbound), do: false
  def recoverable_route?(@route_unkeyed), do: false
  def recoverable_route?(route) when is_binary(route), do: true

  defp keyed_route(nil), do: {:ok, @route_unkeyed}

  defp keyed_route(key) when is_atom(key), do: keyed_route(Atom.to_string(key))

  defp keyed_route(key) when is_binary(key) and key != "" and byte_size(key) <= 512,
    do: {:ok, encode(["key", 1, key])}

  defp keyed_route(_invalid), do: {:error, :invalid_enqueue_key}

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp encode(parts), do: "ash_hooks:" <> Base.url_encode64(Jason.encode!(parts), padding: false)

  defp decode("ash_hooks:" <> encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, parts} when is_list(parts) <- Jason.decode(json) do
      parts
    else
      _ -> :error
    end
  end

  defp decode(_other), do: :error
end
