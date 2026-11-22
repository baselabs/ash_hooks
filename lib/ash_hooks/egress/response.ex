defmodule AshHooks.Egress.Response do
  @moduledoc """
  An HTTP response from one pinned egress attempt.

  `headers` is a list of lowercase name/value pairs. Buffered `body` is a
  binary; streaming `body` is `nil`. `completion` is `:complete`, `:halted`,
  or `:capture_limit`. A halted stream or capped capture does not establish
  that the remote operation completed. `acc` holds the final streaming
  callback accumulator and is `nil` for a buffered request.
  """

  @derive {Inspect, except: [:headers, :body, :acc]}
  defstruct [:status, :headers, :body, :completion, :acc]

  @type t :: %__MODULE__{
          status: integer(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          completion: :complete | :halted | :capture_limit,
          acc: term()
        }
end
