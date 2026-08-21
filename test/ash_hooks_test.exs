defmodule AshHooksTest do
  use ExUnit.Case, async: true
  require Spark.Test

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
      assert is_nil(inbound.provider)
    end

    test "outbound entity parses with its options" do
      outbound = AshHooks.Info.webhooks(Subject) |> Enum.find(&(&1.name == :thing_changed))
      assert outbound.signing_mode == :dual
    end

    test "an explicit provider option parses onto the entity" do
      defmodule ExplicitProvider do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          inbound :mock do
            provider(AshHooks.Provider.Mock)
            secret {AshHooksTest, :secret, []}
          end
        end
      end

      assert [%{provider: AshHooks.Provider.Mock}] = AshHooks.Info.webhooks(ExplicitProvider)
    end
  end

  describe "replay-window-requires-timestamp verifier (fail-closed)" do
    # Verifier errors surface through Spark's after_verify collector, not as
    # raises at the defmodule site — assert via Spark.Test.dsl_errors.
    test "a replay window on a provider with no trustworthy timestamp is rejected" do
      errors =
        Spark.Test.dsl_errors do
          defmodule WindowedNoTimestamp do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshHooks]

            attributes do
              uuid_primary_key :id
            end

            webhooks do
              inbound :mock do
                provider(AshHooks.Provider.Mock)
                secret {AshHooksTest, :secret, []}
                replay_window_seconds 300
              end
            end
          end
        end

      assert [{_module, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "trustworthy timestamp"
    end

    test "a replay window on a provider that declares a timestamp header compiles" do
      defmodule TimestampedProvider do
        @behaviour AshHooks.Provider

        def timestamp_header, do: "x-timestamp"
        def verify_signature(_raw_body, _ctx, _secret), do: :ok
        def parse_event_type(_payload), do: {:ok, :mock}
        def handle_event(_event_type, _payload), do: {:ok, %{}}
      end

      defmodule WindowedTimestamped do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          inbound :timestamped do
            provider(TimestampedProvider)
            secret {AshHooksTest, :secret, []}
            replay_window_seconds 300
          end
        end
      end

      assert [%{replay_window_seconds: 300}] = AshHooks.Info.webhooks(WindowedTimestamped)
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

  describe "parse-time validation" do
    test "literal binary secrets are rejected at compile time" do
      assert_raise Spark.Error.DslError, ~r/literal binary/, fn ->
        defmodule BadSecret do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshHooks]

          attributes do
            uuid_primary_key :id
          end

          webhooks do
            inbound :mock do
              secret "super-secret-bytes"
            end
          end
        end
      end
    end
  end

  describe "Info accessors" do
    test "inbound/outbound are type-disambiguated on name collision" do
      defmodule Collide do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          inbound :thing do
            secret {AshHooksTest, :secret, []}
          end

          outbound :thing do
            signing_mode :legacy
          end
        end
      end

      assert %AshHooks.Inbound{} = AshHooks.Info.inbound(Collide, :thing)
      assert %AshHooks.Outbound{signing_mode: :legacy} = AshHooks.Info.outbound(Collide, :thing)
      assert AshHooks.Info.inbound(Collide, :nonexistent) == nil
      assert AshHooks.Info.outbound(Collide, :nonexistent) == nil
    end
  end
end
