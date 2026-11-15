defmodule AshHooks.Endpoint.Changes.RequireIssuedKeys do
  @moduledoc false
  use Ash.Resource.Change
  alias AshHooks.KeyRegistry.Transitions

  @impl true
  def change(changeset, opts, _context) do
    cond do
      issued_update?(changeset) ->
        changeset

      direct_kind_input?(changeset) ->
        Ash.Changeset.add_error(changeset,
          field: :secret_kind,
          message: "custody key kinds are package-owned"
        )

      changeset.action_type == :update ->
        if direct_ref_input?(changeset), do: require_resolver(changeset, opts), else: changeset

      true ->
        create(changeset, opts)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp issued_update?(changeset),
    do:
      changeset.action.name == :set_custody_keys and
        is_map(changeset.context[:ash_hooks_issued_attributes])

  defp direct_kind_input?(changeset) do
    changeset.resource
    |> Transitions.slots()
    |> Enum.any?(fn {_ref, kind} -> input?(changeset, kind) end)
  end

  defp create(changeset, opts) do
    case changeset.context[:ash_hooks_issued_attributes] do
      nil ->
        require_resolver(changeset, opts)

      attributes ->
        if Keyword.get(opts, :byte_resolver?, false) or not direct_ref_input?(changeset),
          do: Ash.Changeset.force_change_attributes(changeset, attributes),
          else: require_resolver(changeset, opts)
    end
  end

  defp direct_ref_input?(changeset) do
    Enum.any?(
      [:secret_ref, :previous_secret_ref, :legacy_secret_ref, :legacy_previous_secret_ref],
      fn field ->
        input?(changeset, field)
      end
    )
  end

  defp input?(changeset, field),
    do:
      Map.has_key?(changeset.params, field) or
        Map.has_key?(changeset.params, Atom.to_string(field))

  defp require_resolver(changeset, opts) do
    if opts[:byte_resolver?],
      do: changeset,
      else:
        Ash.Changeset.add_error(changeset,
          field: :secret_ref,
          message:
            if(opts[:source?],
              do: "custody sources require create_source/3",
              else: "custody endpoints without a secret_resolver require create_with_key/3"
            )
        )
  end
end
