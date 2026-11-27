defmodule AshHooks.Errors.Unknown.ReplayStoreUnavailable do
  @moduledoc "The durable replay receipt could not be reserved or read. This failure is retryable."

  use Splode.Error, fields: [], class: :unknown

  def message(_error), do: "webhook replay storage is unavailable"
end
