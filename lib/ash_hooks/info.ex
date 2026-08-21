defmodule AshHooks.Info do
  @moduledoc """
  Accessors for a resource's `webhooks` declarations, read via
  `Spark.Dsl.Extension` (the ash_age pattern — no generated getter in this
  spark version).
  """

  alias Spark.Dsl.Extension

  @doc "All webhook entities (inbound + outbound) declared on `resource`."
  @spec webhooks(Ash.Resource.t()) :: [struct()]
  def webhooks(resource), do: Extension.get_entities(resource, [:webhooks])

  @doc "The inbound declaration for `provider`, if any."
  @spec inbound(Ash.Resource.t(), atom()) :: struct() | nil
  def inbound(resource, provider) do
    Enum.find(webhooks(resource), &(&1.name == provider))
  end

  @doc "The outbound declaration for `event`, if any."
  @spec outbound(Ash.Resource.t(), atom()) :: struct() | nil
  def outbound(resource, event) do
    Enum.find(webhooks(resource), &(&1.name == event))
  end
end
