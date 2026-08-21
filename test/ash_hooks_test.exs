defmodule AshHooksTest do
  use ExUnit.Case, async: true

  defmodule Subject do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshHooks]

    attributes do
      uuid_primary_key :id
    end

    webhooks do
      inbound :mock do
        secret {AshHooksTest, :secret, []}
        event_id &AshHooksTest.extract_event_id/1
      end

      outbound :thing_changed do
        signing_mode :dual
      end
    end
  end

  def secret, do: {:ok, "test-secret"}

  def extract_event_id(_payload), do: {:ok, "evt_1"}

  describe "DSL sections" do
    test "inbound entity parses with its options" do
      assert [%{name: :mock}, %{name: :thing_changed}] = AshHooks.Info.webhooks(Subject)
      inbound = AshHooks.Info.webhooks(Subject) |> Enum.find(&(&1.name == :mock))
      assert {AshHooksTest, :secret, []} = inbound.secret
      assert is_function(inbound.event_id)
      assert is_nil(inbound.replay_window_seconds)
    end

    test "outbound entity parses with its options" do
      outbound = AshHooks.Info.webhooks(Subject) |> Enum.find(&(&1.name == :thing_changed))
      assert outbound.signing_mode == :dual
    end

    test "replay_window_seconds accepts a positive integer" do
      defmodule Windowed do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          inbound :hubspot do
            secret {AshHooksTest, :secret, []}
            replay_window_seconds 300
          end
        end
      end

      assert [%{replay_window_seconds: 300}] = AshHooks.Info.webhooks(Windowed)
    end
  end
end
