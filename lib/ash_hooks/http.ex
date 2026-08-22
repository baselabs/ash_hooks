defmodule AshHooks.Http do
  @moduledoc """
  The HTTP adapter behaviour the delivery runtime sends through.

  `request/5` returns `{:ok, %{status: integer, headers: [{name, value}]},
  body :: binary}` or `{:error, term}` — one request, NO redirect
  following (a 3xx must surface as a response the runtime classifies as a
  refused redirect, never be chased). The default implementation is
  `AshHooks.Http.Httpc` (`:httpc`); tests inject a double.

  Adapters SHOULD bound their own connect/receive timeouts (the runtime
  also runs under the Oban job timeout as the outer bound).
  """

  @callback request(atom(), String.t(), map(), binary(), keyword()) ::
              {:ok, %{status: integer(), headers: list(), body: binary() | nil}}
              | {:error, term()}
end
