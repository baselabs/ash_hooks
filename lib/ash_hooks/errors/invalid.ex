defmodule AshHooks.Errors.Invalid do
  @moduledoc "The invalid error class — the webhook input or its verification failed."

  use Splode.ErrorClass, class: :invalid
end
