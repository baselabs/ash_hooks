defmodule AshHooks.Endpoint.Changes.RequireIssuedKeys do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    case changeset.context[:ash_hooks_issued_attributes] do
      nil ->
        require_resolver(changeset, opts)

      attributes ->
        if opts[:byte_resolver?] or not direct_ref_input?(changeset),
          do: Ash.Changeset.force_change_attributes(changeset, attributes),
          else: require_resolver(changeset, opts)
    end
  end

  defp direct_ref_input?(changeset) do
    Enum.any?(
      [:secret_ref, :previous_secret_ref, :legacy_secret_ref, :legacy_previous_secret_ref],
      fn field ->
        Map.has_key?(changeset.params, field) or
          Map.has_key?(changeset.params, Atom.to_string(field))
      end
    )
  end

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
