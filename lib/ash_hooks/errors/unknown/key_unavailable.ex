defmodule AshHooks.Errors.Unknown.KeyUnavailable do
  @moduledoc """
  Custody could not answer a key operation. This failure is retryable.
  Telemetry reason: `:key_unavailable`. Contains no backend error details.
  """

  use Splode.Error, fields: [], class: :unknown

  def message(_error), do: "webhook key custody is unavailable"
end
