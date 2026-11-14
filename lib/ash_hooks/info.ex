defmodule AshHooks.Info do
  @moduledoc """
  Reads compiled webhook declarations and delivery configuration.
  """

  alias Spark.Dsl.Extension

  @doc "All webhook entities (inbound + outbound) declared on `resource`."
  @spec webhooks(Ash.Resource.t()) :: [AshHooks.Inbound.t() | AshHooks.Outbound.t()]
  def webhooks(resource), do: Extension.get_entities(resource, [:webhooks])

  @doc "The inbound declaration for `provider`, if any."
  @spec inbound(Ash.Resource.t(), atom()) :: AshHooks.Inbound.t() | nil
  def inbound(resource, provider) do
    webhooks(resource) |> Enum.find(&(is_struct(&1, AshHooks.Inbound) and &1.name == provider))
  end

  @doc "The outbound declaration for `event`, if any."
  @spec outbound(Ash.Resource.t(), atom()) :: AshHooks.Outbound.t() | nil
  def outbound(resource, event) do
    webhooks(resource) |> Enum.find(&(is_struct(&1, AshHooks.Outbound) and &1.name == event))
  end

  @doc """
  The configured exact-bytes payload attribute name on an
  `AshHooks.OutboundDelivery` resource (default `:payload`).
  """
  @spec payload_attribute(module()) :: atom()
  def payload_attribute(resource),
    do: Extension.get_opt(resource, [:outbound_delivery], :payload_attribute, :payload)

  @doc """
  Returns whether the compiled ingest or dispatch action accepts a
  caller-supplied `:id`.
  """
  @spec writable_id?(module()) :: boolean()
  def writable_id?(resource),
    do: Extension.get_persisted(resource, :id_accepted?) == true
end
