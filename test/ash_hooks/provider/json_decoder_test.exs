defmodule AshHooks.Provider.JsonDecoderTest do
  use ExUnit.Case, async: false
  require Spark.Test

  alias AshHooks.{Ingress, Provider}
  alias AshHooks.Provider.{Scheme, Signature}
  alias AshHooks.Test.Repo

  @moduletag capture_log: true

  defmodule Header do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

    @impl true
    def handle_event(type, payload) do
      send(self(), {:handled, payload})
      super(type, payload)
    end
  end

  defmodule Form do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
    @impl true
    def body_format, do: :form
  end

  defmodule JsonFormat do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
    @impl true
    def body_format, do: :json
  end

  defmodule Legacy do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
    @impl true
    def decode_payload(bytes), do: Jason.decode(bytes)
  end

  defmodule DecoderAware do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
    @impl true
    def decode_payload(bytes, decoder), do: decoder.(bytes)
  end

  defmodule BypassDecoder do
    def decode_payload(bytes, _decoder), do: Jason.decode(bytes)
  end

  defmodule Handwritten do
    @behaviour AshHooks.Provider
    @impl true
    defdelegate verify_signature(bytes, ctx, key), to: Header
    @impl true
    defdelegate parse_event_type(payload), to: Header
    @impl true
    defdelegate handle_event(type, payload), to: Header
    @impl true
    def decode_payload(bytes), do: Jason.decode(bytes)
  end

  defmodule DefinitionHook do
    def on_definition(env, _kind, name, args, _guards, _body) do
      if name in [:decode_payload, :verify_signature],
        do: Module.put_attribute(env.module, :host_definitions, {name, length(args)})
    end

    defmacro __before_compile__(_) do
      quote do
        defoverridable verify_signature: 3, decode_payload: 1
        @impl true
        def verify_signature(_, _, _), do: {:error, :host_verifier}
        @impl true
        def decode_payload(_), do: {:ok, %{"host" => true}}
      end
    end
  end

  for verifier <- [:generated, :host], decoder <- [:generated, :host], two? <- [false, true] do
    Module.create(
      Module.concat(__MODULE__, "#{verifier}_#{decoder}_#{two?}"),
      quote do
        use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: :jws_body]

        unquote(
          if verifier == :host do
            quote do
              @impl true
              def verify_signature(bytes, ctx, key) do
                send(self(), {:host_verifier, ctx.json_decoder})
                super(bytes, ctx, key)
              end
            end
          end
        )

        unquote(
          if decoder == :host do
            quote do
              @impl true
              def decode_payload(bytes) do
                send(self(), :host_decoder_one)
                super(bytes)
              end
            end
          end
        )

        unquote(
          if two? do
            quote do
              @impl true
              def decode_payload(bytes, decoder) do
                send(self(), :host_decoder_two)
                Scheme.decode_payload(bytes, __ash_hooks_scheme__(), decoder)
              end
            end
          end
        )
      end,
      Macro.Env.location(__ENV__)
    )
  end

  defmodule Domain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  setup_all do
    repos =
      [Repo] ++
        if System.get_env("ASH_HOOKS_POSTGRES") == "1", do: [AshHooks.TestPostgres.Repo], else: []

    for repo <- repos do
      {id, payload, time} =
        if repo == Repo, do: {"TEXT", "TEXT", "TEXT"}, else: {"UUID", "JSONB", "TIMESTAMPTZ"}

      repo.query!("""
      CREATE TABLE json_decoder_ingress (
        id #{id} PRIMARY KEY, tenant_id TEXT NOT NULL, policy TEXT NOT NULL,
        provider TEXT NOT NULL, external_event_id TEXT NOT NULL, external_event_type TEXT,
        payload #{payload} NOT NULL, payload_digest TEXT NOT NULL, status TEXT NOT NULL,
        fencing_token INTEGER NOT NULL DEFAULT 0, lease_expires_at #{time}, error_class TEXT,
        attempts INTEGER NOT NULL DEFAULT 0
      )
      """)

      repo.query!("""
      CREATE UNIQUE INDEX json_decoder_ingress_unique_ingest_index
      ON json_decoder_ingress (tenant_id, provider, external_event_id, policy)
      """)
    end

    on_exit(fn -> for repo <- repos, do: repo.query!("DROP TABLE json_decoder_ingress") end)
    {:ok, repos: repos}
  end

  setup %{repos: repos} do
    for repo <- repos, do: repo.query!("DELETE FROM json_decoder_ingress")
    :ok
  end

  for substrate <- [:sqlite, :postgres] do
    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: strict duplicate-member refusal is terminal and reaping never handles it" do
      strict = ledger(Header, :strict, unquote(substrate))
      default = ledger(Header, nil, unquote(substrate))

      for bytes <- [~s({"value":1,"value":2}), ~S({"nested":[{"a":1,"\u0061":2}]})] do
        assert {:ok, :created, row} = ingest(strict, bytes)
        assert_terminal(row)
        refute_received {:handled, _}
        assert {:ok, 0} = Ingress.reap(strict, tenant: "tenant-a")
        refute_received {:handled, _}

        assert {:ok, :duplicate, duplicate} = ingest(strict, bytes)
        assert duplicate.id == row.id
        assert_terminal(duplicate)
        refute_received {:handled, _}

        assert {:ok, :created, %{status: :processed, payload: payload}} = ingest(default, bytes)
        assert payload == Jason.decode!(bytes)
        assert_received {:handled, ^payload}
      end
    end
  end

  test "one request decoder sees JWS header, claims, and delivered payload without a cache" do
    provider = combination(:generated, :generated, false)
    resource = ledger(provider, :sentinel)
    payload = ~s({"id":"original","exp":4102444800})
    bytes = token(payload)

    assert {:ok, :created, %{status: :processed, payload: %{"sentinel" => true}}} =
             Ingress.ingest(resource, :events, bytes, context(resource))

    assert_received {:decoded, ~s({"alg":"HS256"})}
    assert_received {:decoded, ^payload}
    assert_received {:decoded, ^payload}
    refute_received {:decoded, _}

    assert {:ok, %{"id" => "original", "exp" => 4_102_444_800}} = provider.decode_payload(bytes)

    assert {:ok, ^payload} =
             Signature.jws(bytes, "key", alg: "HS256", json_decoder: &decode(&1, :sentinel))

    assert_received {:decoded, ~s({"alg":"HS256"})}
    assert_received {:decoded, ^payload}
  end

  for verifier <- [:generated, :host], decoder <- [:generated, :host], two? <- [false, true] do
    test "sentinel dispatch: verifier #{verifier}, decoder #{decoder}, /2 #{two?}" do
      assert_sentinel_dispatch(unquote(verifier), unquote(decoder), unquote(two?))
    end
  end

  defp assert_sentinel_dispatch(verifier, decoder, two?) do
    provider = combination(verifier, decoder, two?)
    payload = ~s({"original":true})
    bytes = token(payload)
    decode = &__MODULE__.decode(&1, :sentinel)
    assert :ok = provider.verify_signature(bytes, %{json_decoder: decode}, "key")
    assert_received {:decoded, ~s({"alg":"HS256"})}
    assert_received {:decoded, ^payload}
    if verifier == :host, do: assert_received({:host_verifier, ^decode})

    expected =
      if decoder == :host and not two?,
        do: %{"original" => true},
        else: %{"sentinel" => true}

    assert {:ok, ^expected} = Provider.decode_payload(provider, bytes, nil, decode)

    cond do
      decoder == :generated ->
        refute_received :host_decoder_two
        refute_received :host_decoder_one
        assert_received {:decoded, ^payload}

      two? ->
        assert_received :host_decoder_two
        refute_received :host_decoder_one
        assert_received {:decoded, ^payload}

      true ->
        assert_received :host_decoder_one
        refute_received {:decoded, _}
    end
  end

  test "generated decoding honors the ledger when an overriding verifier ignores its decoder" do
    provider = unique_module("IgnoringVerifier")

    Module.create(
      provider,
      quote do
        use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: :jws_body]
        @impl true
        def verify_signature(bytes, _ctx, key), do: super(bytes, %{}, key)
      end,
      Macro.Env.location(__ENV__)
    )

    ledger = ledger(provider, :sentinel)

    assert {:ok, :created, %{payload: %{"sentinel" => true}}} =
             Ingress.ingest(ledger, :events, token("{}"), context(ledger))

    assert_received {:decoded, "{}"}
    refute_received {:decoded, _}
  end

  test "decode precedence preserves explicit formats, provider callbacks, formats, and JSON" do
    decode = &__MODULE__.decode(&1, :sentinel)
    jws = combination(:generated, :generated, false)

    for provider <- [Header, JsonFormat, DecoderAware, Legacy, jws] do
      assert {:ok, %{"sentinel" => true}} = Provider.decode_payload(provider, "{}", :json, decode)
    end

    for provider <- [Header, JsonFormat, DecoderAware] do
      assert {:ok, %{"sentinel" => true}} = Provider.decode_payload(provider, "{}", nil, decode)
    end

    assert {:ok, %{}} = Provider.decode_body("{}", :json)
    assert {:ok, %{}} = Provider.decode_payload(Header, "{}", nil)
    assert {:ok, %{"a" => "1"}} = Provider.decode_payload(Form, "a=1", nil, decode)
    assert {:ok, %{"a" => "1"}} = Provider.decode_payload(jws, "a=1", :form, decode)

    assert {:error, :malformed_payload} =
             Provider.decode_payload(jws, token("{}"), :json, &Jason.decode/1)

    assert {:ok, %{"original" => true}} =
             Provider.decode_payload(Legacy, ~s({"original":true}), nil, decode)
  end

  for mode <- [:untouched, :body, :before_compile, :own_hook] do
    test "definition origins and override dispatch: #{mode}" do
      provider = definition_probe(unquote(mode))
      expected = if unquote(mode) == :untouched, do: [:generated], else: [:generated, :host]

      definitions =
        provider.__info__(:attributes)
        |> Keyword.get_values(:ash_hooks_provider_definitions)
        |> List.flatten()

      for callback <- [verify_signature: 3, decode_payload: 1] do
        assert for({^callback, origin} <- definitions, do: origin) == expected
      end

      if unquote(mode) == :untouched do
        assert :ok = provider.verify_signature(token("{}"), %{}, "key")
        assert {:ok, %{}} = provider.decode_payload(token("{}"))
      else
        assert {:error, :host_verifier} = provider.verify_signature("", %{}, "key")
        assert {:ok, %{"host" => true}} = provider.decode_payload("")

        assert {:ok, %{"host" => true}} =
                 Provider.decode_payload(provider, "", nil, &Jason.decode/1)
      end

      if unquote(mode) == :own_hook do
        host_definitions =
          provider.__info__(:attributes)
          |> Keyword.get_values(:host_definitions)
          |> List.flatten()

        assert {:verify_signature, 3} in host_definitions
        assert {:decode_payload, 1} in host_definitions
      end
    end
  end

  test "opted-in ledgers require /2 for every host /1, including late overrides" do
    for verifier <- [:generated, :host], two? <- [false, true] do
      assert ledger(combination(verifier, :generated, two?), :strict)
      assert ledger(combination(verifier, :host, true), :strict)
    end

    assert ledger(DecoderAware, :strict)

    for provider <- [
          Handwritten,
          Legacy,
          definition_probe(:before_compile),
          combination(:generated, :host, false),
          combination(:host, :host, false)
        ] do
      for decoder <- [:strict, {Jason, :decode, []}] do
        errors =
          Spark.Test.dsl_errors do
            ledger(provider, decoder)
          end

        assert [{_, [%Spark.Error.DslError{} = error]}] = errors,
               "expected decoder guard for #{inspect(provider)} with #{inspect(decoder)}"

        assert error.message =~ "decode_payload/2"
        assert error.message =~ inspect(provider)
      end

      assert ledger(provider, nil)
    end
  end

  test "all verifier and decoder combinations keep compiling on default ledgers" do
    for verifier <- [:generated, :host], decoder <- [:generated, :host], two? <- [false, true] do
      assert ledger(combination(verifier, decoder, two?), nil)
    end
  end

  test "explicit decoder opt-in does not depend on compiler debug info" do
    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, false)

    try do
      errors =
        Spark.Test.dsl_errors do
          ledger(Legacy, {Jason, :decode, []})
        end

      assert [{_, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "decode_payload/2"
      assert ledger(combination(:generated, :generated, false), {Jason, :decode, []})
      assert ledger(Legacy, nil)
    after
      Code.put_compiler_option(:debug_info, previous)
    end
  end

  test "a scalar returned by an existing host decoder is also written terminal" do
    resource = ledger(Legacy, nil)
    assert {:ok, :created, row} = ingest(resource, "42")
    assert_terminal(row)
    assert {:ok, 0} = Ingress.reap(resource, tenant: "tenant-a")
  end

  for substrate <- [:sqlite, :postgres] do
    if substrate == :postgres, do: @tag(:postgres)

    test "#{substrate}: decoder errors, exceptions, and invalid shapes use terminal malformed recording" do
      for mode <- [:error, :raise, :throw, :exit, :scalar, :invalid] do
        ledger = ledger(Header, mode, unquote(substrate))
        assert {:ok, :created, row} = ingest(ledger, "{}")
        assert_terminal(row)
        assert {:ok, 0} = Ingress.reap(ledger, tenant: "tenant-a")
        refute_received {:handled, _}
      end
    end
  end

  test "JWS decoder failures are malformed payloads and malformed claim types are InvalidSignature" do
    provider = combination(:generated, :generated, false)

    for mode <- [:error, :raise, :throw, :exit, :scalar, :invalid, :claims_error, :claims_raise] do
      ledger = ledger(provider, mode)

      assert {:error, %AshHooks.Errors.Invalid.MalformedPayload{}} =
               Ingress.ingest(ledger, :events, token("{}"), context(ledger))
    end

    for claim <- [~s({"exp":"later"}), ~s({"nbf":null})] do
      ledger = ledger(provider, :strict)

      assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
               Ingress.ingest(ledger, :events, token(claim), context(ledger))
    end

    ledger = ledger(provider, :bad_claim)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             Ingress.ingest(ledger, :events, token("{}"), context(ledger))
  end

  test "direct scheme decoding uses the supplied decoder and accepts JSON lists" do
    scheme = Scheme.new!(algorithm: :hmac_sha256, signature: :jws_body)
    assert {:ok, [%{"value" => 1}]} = Scheme.decode_payload(token(~s([{"value":1}])), scheme)

    assert {:ok, %{"sentinel" => true}} =
             Scheme.decode_payload(token("{}"), scheme, &decode(&1, :sentinel))
  end

  test "conformance passes a supplied decoder and trips a provider decoding directly with Jason" do
    for {provider, correct?} <- [{DecoderAware, true}, {BypassDecoder, false}] do
      module = unique_module("Conformance")

      Module.create(
        module,
        quote do
          use AshHooks.Provider.Conformance, provider: unquote(provider), register: false
        end,
        Macro.Env.location(__ENV__)
      )

      [test] = module.__ex_unit__().tests

      if correct? do
        apply(module, test.name, [%{}])
      else
        assert_raise ExUnit.AssertionError, fn -> apply(module, test.name, [%{}]) end
      end
    end
  end

  test "the shipped conformance template compiles without ExUnit on the code path" do
    program = ~S"""
    true = :code.del_path(:code.lib_dir(:ex_unit, :ebin))
    false = Code.ensure_loaded?(ExUnit.Case)
    Code.compile_file("lib/ash_hooks/provider/conformance.ex")
    true = function_exported?(AshHooks.Provider.Conformance, :"MACRO-__using__", 2)
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-e", program], stderr_to_stdout: true)

    assert status == 0, output
    refute :ex_unit in Application.spec(:ash_hooks, :applications)
  end

  def decode(bytes, :strict) do
    with {:ok, value} <- Jason.decode(bytes, objects: :ordered_objects), do: normalize(value)
  end

  def decode(_bytes, :error), do: {:error, :decoder_policy}
  def decode(_bytes, :raise), do: raise("decoder failure")
  def decode(_bytes, :throw), do: throw(:decoder_failure)
  def decode(_bytes, :exit), do: exit(:decoder_failure)
  def decode(_bytes, :scalar), do: {:ok, 1}
  def decode(_bytes, :invalid), do: :invalid

  def decode(bytes, mode) do
    send(self(), {:decoded, bytes})

    with {:ok, value} <- Jason.decode(bytes), do: decoded(value, mode)
  end

  defp decoded(%{"alg" => _} = header, _mode), do: {:ok, header}
  defp decoded(_value, :sentinel), do: {:ok, %{"sentinel" => true}}
  defp decoded(_value, :bad_claim), do: {:ok, %{"exp" => "later"}}
  defp decoded(_value, :claims_error), do: {:error, :claims_policy}
  defp decoded(_value, :claims_raise), do: raise("claims decoder failure")

  defp normalize(%Jason.OrderedObject{values: members}) do
    Enum.reduce_while(members, {:ok, %{}}, fn {key, value}, {:ok, map} ->
      with false <- Map.has_key?(map, key), {:ok, decoded} <- normalize(value) do
        {:cont, {:ok, Map.put(map, key, decoded)}}
      else
        _ -> {:halt, {:error, :duplicate_member}}
      end
    end)
  end

  defp normalize(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize(value) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize(value), do: {:ok, value}

  defp definition_probe(mode) do
    provider = unique_module("Probe")

    overrides =
      quote do
        @impl true
        def verify_signature(_, _, _), do: {:error, :host_verifier}
        @impl true
        def decode_payload(_), do: {:ok, %{"host" => true}}
      end

    Module.create(
      provider,
      quote do
        use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: :jws_body]

        unquote(
          if mode == :own_hook do
            quote do
              Module.register_attribute(__MODULE__, :host_definitions,
                accumulate: true,
                persist: true
              )

              @on_definition {AshHooks.Provider.JsonDecoderTest.DefinitionHook, :on_definition}
            end
          end
        )

        unquote(
          if mode == :before_compile do
            quote do
              @before_compile AshHooks.Provider.JsonDecoderTest.DefinitionHook
            end
          end
        )

        unquote(if mode in [:body, :own_hook], do: overrides)
      end,
      Macro.Env.location(__ENV__)
    )

    provider
  end

  defp ledger(provider, decoder, substrate \\ :sqlite) do
    resource = unique_module("Ledger")

    decoder =
      if is_atom(decoder) and not is_nil(decoder),
        do: {__MODULE__, :decode, [decoder]},
        else: decoder

    config =
      if decoder do
        quote do
          json_decoder unquote(Macro.escape(decoder))
        end
      end

    storage =
      if substrate == :sqlite do
        quote do
          sqlite do
            table "json_decoder_ingress"
            repo(AshHooks.Test.Repo)
          end
        end
      else
        quote do
          postgres do
            table "json_decoder_ingress"
            repo(AshHooks.TestPostgres.Repo)
          end
        end
      end

    data_layer = if substrate == :sqlite, do: AshSqlite.DataLayer, else: AshPostgres.DataLayer

    Module.create(
      resource,
      quote do
        use Ash.Resource,
          domain: AshHooks.Provider.JsonDecoderTest.Domain,
          data_layer: unquote(data_layer),
          extensions: [AshHooks, AshHooks.InboundDelivery]

        unquote(storage)

        inbound_delivery do
          scope_identity [:policy]
          unquote(config)
        end

        attributes do
          attribute :policy, :string, allow_nil?: false
          attribute :tenant_id, :string, allow_nil?: false
        end

        multitenancy do
          strategy :attribute
          attribute :tenant_id
        end

        actions do
          defaults [:read]
        end

        webhooks do
          inbound :events do
            provider(unquote(provider))
            secret {AshHooks.Provider.JsonDecoderTest, :secret, []}
          end
        end
      end,
      Macro.Env.location(__ENV__)
    )

    resource
  end

  def secret, do: {:ok, "key"}
  defp context(ledger), do: %{tenant: "tenant-a", scope: %{policy: Atom.to_string(ledger)}}

  defp ingest(ledger, bytes) do
    signature = :crypto.mac(:hmac, :sha256, "key", bytes) |> Base.encode16(case: :lower)

    Ingress.ingest(
      ledger,
      :events,
      bytes,
      Map.put(context(ledger), :headers, %{"x-signature" => signature})
    )
  end

  defp assert_terminal(row) do
    assert row.status == :failed_permanent
    assert row.error_class == "malformed_payload"
    assert row.payload == %{}
    assert row.attempts == 0
    assert row.fencing_token == 0
    assert row.lease_expires_at == nil
  end

  defp token(payload) do
    input =
      Base.url_encode64(~s({"alg":"HS256"}), padding: false) <>
        "." <> Base.url_encode64(payload, padding: false)

    input <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, "key", input), padding: false)
  end

  defp combination(verifier, decoder, two?),
    do: Module.concat(__MODULE__, "#{verifier}_#{decoder}_#{two?}")

  defp unique_module(label),
    do: Module.concat(__MODULE__, "#{label}#{System.unique_integer([:positive])}")
end
