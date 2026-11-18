defmodule AshHooks.CustodyOnlyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias AshHooks.Provider.Signature
  alias AshHooks.Test.Dsl

  setup do
    previous = Application.fetch_env(:ash_hooks, :key_material)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_hooks, :key_material, value)
        :error -> Application.delete_env(:ash_hooks, :key_material)
      end
    end)

    :ok
  end

  test "every inbound byte-source shape is accepted by default and refused in custody-only mode" do
    for source <- [
          quote(do: {:app_env, [:ash_hooks, :secret]}),
          quote(do: {__MODULE__, :secret, []}),
          quote(do: fn -> {:ok, "key"} end),
          quote(do: fn _tenant -> {:ok, "key"} end)
        ],
        option <- [:secret, :previous_secret] do
      definition =
        quote do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Simple, extensions: [AshHooks]

          webhooks do
            inbound :checked do
              provider AshHooks.Test.CustodyHmacProvider

              unquote(
                if option == :previous_secret, do: quote(do: secret(fn -> {:ok, "current"} end))
              )

              unquote({option, [], [source]})
            end
          end
        end

      compile_in_modes(definition, Spark.Error.DslError)
    end
  end

  test "provider signing-secret callbacks are refused with configured and plain providers" do
    for arity <- [1, 2], configured? <- [true, false] do
      callback =
        if arity == 1 do
          quote do
            @impl true
            def webhook_signing_secret(_connection), do: {:ok, "key"}
          end
        else
          quote do
            @impl true
            def webhook_signing_secret(_connection, _tenant), do: {:ok, "key"}
          end
        end

      definition =
        if configured? do
          quote do
            use AshHooks.Provider,
              verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
          end
        else
          quote do
            use AshHooks.Provider

            @impl true
            def verify_signature(body, ctx, key),
              do: Signature.hmac(body, ctx.signature, key)

            @impl true
            def parse_event_type(_), do: {:ok, :checked}
            @impl true
            def handle_event(type, payload),
              do: {:ok, %AshHooks.Event{type: type, payload: payload}}
          end
        end

      compile_in_modes(
        quote do
          unquote(definition)
          unquote(callback)
        end,
        ArgumentError
      )
    end
  end

  test "the generated missing-secret default is accepted in custody-only mode" do
    Application.put_env(:ash_hooks, :key_material, :custody_only)

    compile(
      quote do
        use AshHooks.Provider,
          verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
      end
    )
  end

  test "provider callback inspection loads providers compiled before custody-only mode" do
    provider = Module.concat(__MODULE__, "StoredProvider#{System.unique_integer([:positive])}")

    directory =
      Path.join(System.tmp_dir!(), "custody-provider-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    try do
      [{^provider, beam}] =
        Code.compile_quoted(
          quote do
            defmodule unquote(provider) do
              @behaviour AshHooks.Provider

              @impl true
              def webhook_signing_secret(_connection), do: {:ok, "key"}
              @impl true
              def verify_signature(body, ctx, key),
                do: Signature.hmac(body, ctx.signature, key)

              @impl true
              def parse_event_type(_), do: {:ok, :checked}
              @impl true
              def handle_event(type, payload),
                do: {:ok, %AshHooks.Event{type: type, payload: payload}}
            end
          end
        )

      declaration =
        quote do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Simple, extensions: [AshHooks]

          webhooks do
            inbound :checked do
              provider unquote(provider)
              secret fn -> {:ok, "key"} end
            end
          end
        end

      Application.delete_env(:ash_hooks, :key_material)
      compile(declaration)
      File.write!(Path.join(directory, Atom.to_string(provider) <> ".beam"), beam)
      true = :code.add_patha(String.to_charlist(directory))
      :code.purge(provider)
      :code.delete(provider)
      assert :code.is_loaded(provider) == false
      Application.put_env(:ash_hooks, :key_material, :custody_only)
      assert AshHooks.Provider.byte_secret_callback?(provider)

      errors =
        Dsl.errors(fn ->
          compile(declaration)
        end)

      assert [{_, [error]}] = errors
      assert Exception.message(error) =~ "custody_only"
    after
      :code.purge(provider)
      :code.delete(provider)
      :code.del_path(String.to_charlist(directory))
      File.rm_rf!(directory)
    end
  end

  test "workers refuse resolvers in custody-only mode and custody workers need no byte resolver" do
    if Code.ensure_loaded?(Oban) do
      compile_in_modes(
        quote do
          use AshHooks.Worker,
            deliveries: AshHooks.CustodySigningTest.SigningEndpoint.Delivery,
            endpoints: AshHooks.CustodySigningTest.SigningEndpoint,
            secret_resolver: {__MODULE__, :resolve}
        end,
        ArgumentError
      )
    end
  end

  test "an endpoint byte resolver is refused in custody-only mode" do
    compile_in_modes(
      quote do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer,
          extensions: [AshHooks.Endpoint]

        sqlite do
          repo(AshHooks.Test.Repo)
          table "custody_only_endpoints"
        end

        endpoint do
          secret_resolver({__MODULE__, :resolve})
        end

        actions do
          defaults [:read]
        end
      end,
      Spark.Error.DslError
    )
  end

  defp compile_in_modes(body, error_module) do
    Application.delete_env(:ash_hooks, :key_material)
    compile(body)
    Application.put_env(:ash_hooks, :key_material, :custody_only)

    if error_module == Spark.Error.DslError do
      errors =
        Dsl.errors(fn ->
          compile(body)
        end)

      assert [{_, [error]}] = errors
      assert Exception.message(error) =~ "custody_only"
    else
      assert_raise error_module, ~r/custody_only/, fn -> compile(body) end
    end
  end

  defp compile(body) do
    module = Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")

    capture_log(fn ->
      try do
        Module.create(module, body, Macro.Env.location(__ENV__))
      after
        :code.purge(module)
        :code.delete(module)
      end
    end)
  end
end
