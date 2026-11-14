defmodule AshHooks.OutboundAttempt.Transformers.AddAttemptFields do
  @moduledoc false
  # Injects the attempt-history attributes and a client-writable uuid
  # primary key when the resource declares none (the ledger pattern).
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, dsl_state} <- add_primary_key(dsl_state) do
      add_attributes(dsl_state)
    end
  end

  defp add_primary_key(dsl_state) do
    has_pk? =
      dsl_state
      |> get_attributes()
      |> Enum.any?(& &1.primary_key?)

    if has_pk? do
      {:ok, dsl_state}
    else
      Builder.add_new_attribute(dsl_state, :id, :uuid,
        primary_key?: true,
        writable?: true,
        allow_nil?: false,
        default: &Ash.UUID.generate/0
      )
    end
  end

  defp add_attributes(dsl_state) do
    Enum.reduce_while(attributes_spec(), {:ok, dsl_state}, fn {name, type, opts},
                                                              {:ok, dsl_state} ->
      {:cont, Builder.add_new_attribute(dsl_state, name, type, opts)}
    end)
  end

  defp get_attributes(dsl_state), do: Transformer.get_entities(dsl_state, [:attributes])

  defp attributes_spec do
    [
      # the complete encoded delivery key (AshHooks.PrimaryKey.encode shape):
      # the row link, stable under composite and custom delivery keys
      {:delivery_pk, :map, [allow_nil?: false]},
      {:endpoint_id, :uuid, [allow_nil?: false]},
      {:event_uuid, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:event_type, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:attempt, :integer, [allow_nil?: false, constraints: [min: 1]]},
      {:outcome, :atom,
       [allow_nil?: false, constraints: [one_of: AshHooks.OutboundAttempt.outcomes()]]},
      {:reason, :string, [constraints: [max_length: 255]]},
      {:response_status, :integer, []},
      {:response_snippet, :string, [constraints: [max_length: 2048]]},
      # allowlisted response headers only (per-endpoint capture opt-in)
      {:response_headers, :map, []},
      {:latency_ms, :integer, [constraints: [min: 0]]},
      # a secret STORE REFERENCE string, never secret material
      {:signing_key_ref, :string, [constraints: [max_length: 255]]},
      # test sends flag their history rows (test_tracking deliveries)
      {:test, :boolean, [allow_nil?: false, default: false]},
      {:attempted_at, :utc_datetime_usec, [allow_nil?: false, default: &DateTime.utc_now/0]}
    ]
  end
end
