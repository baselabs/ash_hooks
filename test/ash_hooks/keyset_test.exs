defmodule AshHooks.KeysetTest do
  @moduledoc """
  Page cursors decode attacker-shaped input without raising, whatever the
  resource's id type: a cast that raises, or a resource without an `:id`
  attribute, is the named `{:error, :invalid_cursor}`.
  """
  use ExUnit.Case, async: true

  defmodule FloatId do
    @moduledoc false
    use Ash.Resource, domain: AshHooks.KeysetTest.Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      attribute :id, :float, primary_key?: true, allow_nil?: false, public?: true
      attribute :inserted_at, :utc_datetime_usec, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule NamedKey do
    @moduledoc false
    use Ash.Resource, domain: AshHooks.KeysetTest.Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      attribute :key, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :inserted_at, :utc_datetime_usec, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource FloatId
      resource NamedKey
    end
  end

  defp cursor(id) do
    %{"time" => DateTime.to_iso8601(DateTime.utc_now()), "id" => id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp page(resource, cursor),
    do: AshHooks.Keyset.read_page(resource, [after: cursor], :inserted_at, & &1, nil)

  test "an id whose cast raises is a named error" do
    assert {:error, :invalid_cursor} = page(FloatId, cursor(Integer.pow(10, 400)))
  end

  test "a resource without an id attribute refuses every cursor by name" do
    assert {:error, :invalid_cursor} = page(NamedKey, cursor("a-key"))
  end

  test "a castable id still reads its page" do
    assert {:ok, %{records: [], next_cursor: nil}} = page(FloatId, cursor(1.5))
  end
end
