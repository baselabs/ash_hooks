defmodule AshHooks.InboundSource.Transformers.AddSourceFields do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Spark.Dsl.{Extension, Transformer}
  alias Spark.Error.DslError

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(state) do
    source = Extension.get_opt(state, [:inbound_source], :source_attribute, :source)
    scope = Extension.get_opt(state, [:inbound_source], :scope, [])
    roles = [source | Enum.map(scope, &elem(&1, 0))]

    with :ok <- check_roles(state, roles),
         {:ok, state} <- primary_key(state),
         {:ok, state} <- inject(state, attributes_spec(state)) do
      Builder.add_identity(state, :unique_source, roles)
    end
  end

  def attributes_spec(state) do
    source = Extension.get_opt(state, [:inbound_source], :source_attribute, :source)
    scope = Extension.get_opt(state, [:inbound_source], :scope, [])
    aliases = Keyword.keys(Extension.get_opt(state, [:inbound_source], :providers, []))

    [
      {source, :atom, [allow_nil?: false]}
      | Enum.map(scope, fn {name, type, constraints} ->
          {name, type, [allow_nil?: false, constraints: constraints]}
        end)
    ] ++ fixed_specs(aliases)
  end

  defp check_roles(state, roles) do
    reserved = Enum.map(fixed_specs([]), &elem(&1, 0))

    if length(Enum.uniq(roles)) == length(roles) and
         Enum.all?(roles, &(&1 not in [:id | reserved])),
       do: :ok,
       else:
         error(
           state,
           "source_attribute and scope names must be distinct and cannot collide with injected fields"
         )
  end

  defp primary_key(state) do
    if Enum.any?(Transformer.get_entities(state, [:attributes]), & &1.primary_key?),
      do: {:ok, state},
      else:
        Builder.add_new_attribute(state, :id, :uuid,
          primary_key?: true,
          allow_nil?: false,
          writable?: true,
          default: &Ash.UUID.generate/0
        )
  end

  defp inject(state, specs) do
    Enum.reduce_while(specs, {:ok, state}, fn {name, type, opts}, {:ok, state} ->
      {:cont, Builder.add_new_attribute(state, name, type, Keyword.put(opts, :public?, true))}
    end)
  end

  defp fixed_specs(aliases) do
    [
      {:provider, :atom, [allow_nil?: false, constraints: [one_of: aliases]]},
      {:secret_ref, AshHooks.Endpoint.SecretRef, []},
      {:previous_secret_ref, AshHooks.Endpoint.SecretRef, []},
      {:secret_kind, :term, []},
      {:previous_secret_kind, :term, []},
      {:public_key, :term, []},
      {:public_key_kind, :term, []},
      {:paused, :boolean, [allow_nil?: false, default: false]}
    ] ++
      Enum.map(
        ~w(secret_created_at secret_first_used_at previous_secret_created_at previous_secret_first_used_at previous_secret_retired_at)a,
        &{&1, :utc_datetime_usec, []}
      )
  end

  defp error(state, message),
    do:
      {:error,
       DslError.exception(
         module: Transformer.get_persisted(state, :module),
         path: [:inbound_source],
         message: message
       )}
end
