defmodule AshHooks.Errors.Unknown do
  @moduledoc "The unknown error class — unrecognized failures inside ash_hooks."

  use Splode.ErrorClass, class: :unknown
end
