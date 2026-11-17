# Igniter is an optional dev/test dependency (present in both CI legs of
# this repo's own build); skipped where absent.
if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.AshHooksInstallTest do
    @moduledoc "Endpoint body_reader codemod: idempotent, scoped to Plug.Parsers."

    use ExUnit.Case, async: false

    alias Igniter.Test
    alias Mix.Tasks.AshHooks.Install
    alias Rewrite.Source

    @endpoint_source """
    defmodule MyAppWeb.Endpoint do
      use Phoenix.Endpoint, otp_app: :my_app

      plug Plug.RequestId
      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library()

      plug Plug.MethodOverride
      plug Plug.Head
    end
    """

    test "patches the endpoint's Plug.Parsers with the body_reader" do
      igniter =
        Test.test_project(files: %{"lib/my_app_web/endpoint.ex" => @endpoint_source})
        |> Install.igniter()

      assert render(igniter, "lib/my_app_web/endpoint.ex") =~
               "body_reader: {AshHooks.BodyReader, :read_body, []}"
    end

    test "does not touch a second plug's options" do
      igniter =
        Test.test_project(files: %{"lib/my_app_web/endpoint.ex" => @endpoint_source})
        |> Install.igniter()

      content = render(igniter, "lib/my_app_web/endpoint.ex")
      assert content =~ "plug(Plug.RequestId)"
      assert content =~ "json_decoder: Phoenix.json_library()"
    end

    test "is idempotent: running twice adds the option once" do
      once =
        Test.test_project(files: %{"lib/my_app_web/endpoint.ex" => @endpoint_source})
        |> Install.igniter()

      twice = Install.igniter(once)

      assert render(twice, "lib/my_app_web/endpoint.ex") ==
               render(once, "lib/my_app_web/endpoint.ex")
    end

    test "an endpoint without Plug.Parsers is left unchanged" do
      source = """
      defmodule MyAppWeb.Endpoint do
        use Phoenix.Endpoint, otp_app: :my_app

        plug Plug.RequestId
      end
      """

      igniter =
        Test.test_project(files: %{"lib/my_app_web/endpoint.ex" => source})
        |> Install.igniter()

      # formatting may normalize, but the codemod must not introduce the
      # body_reader anywhere
      refute render(igniter, "lib/my_app_web/endpoint.ex") =~ "body_reader"

      assert Enum.any?(
               igniter.notices,
               &String.contains?(&1, "Configure Plug.Parsers with body_reader:")
             )
    end

    defp install(source) do
      Test.test_project(files: %{"lib/my_app_web/endpoint.ex" => source}) |> Install.igniter()
    end

    test "retains an existing custom body reader and explains the raw body handoff" do
      source =
        String.replace(
          @endpoint_source,
          "parsers: [:urlencoded",
          "body_reader: {MyApp.Reader, :read, []},\n    parsers: [:urlencoded"
        )

      igniter = install(source)
      content = render(igniter, "lib/my_app_web/endpoint.ex")
      assert content =~ "body_reader: {MyApp.Reader, :read, []}"
      refute content =~ "{AshHooks.BodyReader, :read_body, []}"

      assert Enum.any?(
               igniter.notices,
               &String.contains?(
                 &1,
                 "must call AshHooks.BodyReader.put_raw_body/2 with the complete body"
               )
             )

      twice = Install.igniter(igniter)
      assert render(twice, "lib/my_app_web/endpoint.ex") == content
      assert twice.notices == igniter.notices
    end

    for reader <- ["AshHooks.BodyReader", "Elixir.AshHooks.BodyReader", "Reader"] do
      test "retains the existing #{reader} reader without a notice" do
        source =
          @endpoint_source
          |> String.replace(
            "plug Plug.RequestId",
            "alias AshHooks.BodyReader, as: Reader\n  plug Plug.RequestId"
          )
          |> String.replace(
            "parsers: [:urlencoded",
            "body_reader: {" <> unquote(reader) <> ", :read_body, []},\n    parsers: [:urlencoded"
          )

        igniter = install(source)
        assert igniter.notices == []

        assert render(Install.igniter(igniter), "lib/my_app_web/endpoint.ex") ==
                 render(igniter, "lib/my_app_web/endpoint.ex")
      end
    end

    test "a missing endpoint emits the manual step" do
      igniter = Test.test_project() |> Install.igniter()

      assert Enum.any?(
               igniter.notices,
               &String.contains?(&1, "No endpoint with Plug.Parsers was found")
             )
    end

    test "recognizes a body reader declared in a grouped alias" do
      source =
        @endpoint_source
        |> String.replace(
          "plug Plug.RequestId",
          "alias AshHooks.{BodyReader, Provider}\n  plug Plug.RequestId"
        )
        |> String.replace(
          "parsers: [:urlencoded",
          "body_reader: {BodyReader, :read_body, []},\n    parsers: [:urlencoded"
        )

      igniter = install(source)
      assert igniter.notices == []

      assert render(igniter, "lib/my_app_web/endpoint.ex") =~
               "body_reader: {BodyReader, :read_body, []}"
    end

    test "adds the formatter import exactly once" do
      igniter = install(@endpoint_source)
      twice = Install.igniter(igniter)
      formatter = render(twice, ".formatter.exs")
      assert formatter =~ ":ash_hooks"
      assert length(Regex.scan(~r/:ash_hooks/, formatter)) == 1
    end

    test "patches every parser call and leaves other files alone" do
      source =
        @endpoint_source <>
          String.replace(@endpoint_source, "MyAppWeb.Endpoint", "MyAppWeb.OtherEndpoint")

      igniter =
        Test.test_project(
          files: %{
            "lib/my_app_web/endpoint.ex" => source,
            "lib/my_app_web/router.ex" => @endpoint_source
          }
        )
        |> Install.igniter()

      assert length(Regex.scan(~r/body_reader:/, render(igniter, "lib/my_app_web/endpoint.ex"))) ==
               2

      refute render(igniter, "lib/my_app_web/router.ex") =~ "body_reader:"
    end

    defp render(igniter, path) do
      igniter.rewrite |> Rewrite.source!(path) |> Source.get(:content)
    end

    describe "parsers argument shapes" do
      test "resolves aliases rooted in the current module" do
        source =
          @endpoint_source
          |> String.replace("MyAppWeb.Endpoint", "Plug")
          |> String.replace(
            "plug Plug.RequestId",
            "alias __MODULE__.Parsers, as: X\n  plug Plug.RequestId"
          )
          |> String.replace("plug Plug.Parsers,", "plug X,")

        igniter = install(source)

        assert render(igniter, "lib/my_app_web/endpoint.ex") =~
                 "body_reader: {AshHooks.BodyReader, :read_body, []}"

        assert igniter.notices == []
      end

      test "aliases from another module or later in the file do not match" do
        source = """
        defmodule Other.Endpoint do
          alias Plug.Parsers
        end
        defmodule MyAppWeb.Endpoint do
          plug Parsers, parsers: [:json]
          alias Plug.Parsers
        end
        """

        igniter = install(source)
        refute render(igniter, "lib/my_app_web/endpoint.ex") =~ "body_reader"
        assert Enum.any?(igniter.notices, &String.contains?(&1, "No Plug.Parsers call was found"))
      end

      for {declaration, spelling} <- [
            {"", ~s(:"Elixir.Plug.Parsers")},
            {"alias Elixir.Plug.Parsers, as: X", "X"},
            {"", "Elixir.Plug.Parsers"},
            {"alias Plug.Parsers", "Parsers"},
            {"alias Plug.{Conn, Parsers}", "Parsers"},
            {"alias Plug.{Conn, Parsers}, warn: false", "Parsers"},
            {"alias Elixir.Plug.Parsers", "Parsers"},
            {"alias Plug.Parsers, as: X", "X"},
            {"alias Plug, as: P", "P.Parsers"},
            {"alias Plug.Parsers, as: X", "Elixir.Plug.Parsers"}
          ] do
        test "resolves #{declaration} with #{spelling}" do
          source =
            @endpoint_source
            |> String.replace(
              "plug Plug.RequestId",
              unquote(declaration) <> "\n  plug Plug.RequestId"
            )
            |> String.replace("plug Plug.Parsers,", "plug " <> unquote(spelling) <> ",")

          igniter = install(source)

          assert render(igniter, "lib/my_app_web/endpoint.ex") =~
                   "body_reader: {AshHooks.BodyReader, :read_body, []}"

          assert igniter.notices == []

          assert render(Install.igniter(igniter), "lib/my_app_web/endpoint.ex") ==
                   render(igniter, "lib/my_app_web/endpoint.ex")
        end
      end

      for options <- [
            "@parser_options",
            "Keyword.merge(@parser_options, parsers: [:json])",
            "[:json]"
          ] do
        test "leaves #{options} options untouched with the manual step" do
          source = """
          defmodule MyAppWeb.Endpoint do
            use Phoenix.Endpoint, otp_app: :my_app
            plug Plug.Parsers, #{unquote(options)}
          end
          """

          igniter = install(source)
          refute render(igniter, "lib/my_app_web/endpoint.ex") =~ "body_reader"
          assert Enum.any?(igniter.notices, &String.contains?(&1, "not a literal keyword list"))
        end
      end

      test "does not confuse an unrelated alias named Parsers with Plug.Parsers" do
        source =
          @endpoint_source
          |> String.replace("plug Plug.RequestId", "alias Other.Parsers\n  plug Plug.RequestId")
          |> String.replace("plug Plug.Parsers,", "plug Parsers,")

        igniter = install(source)
        refute render(igniter, "lib/my_app_web/endpoint.ex") =~ "body_reader"
        assert Enum.any?(igniter.notices, &String.contains?(&1, "No Plug.Parsers call was found"))
      end

      test "an atom with a different module name is left alone with a manual notice" do
        source = String.replace(@endpoint_source, "plug Plug.Parsers,", ~s(plug :"Plug.Parsers",))
        igniter = install(source)
        refute render(igniter, "lib/my_app_web/endpoint.ex") =~ "body_reader"

        assert Enum.any?(
                 igniter.notices,
                 &String.contains?(&1, "Configure Plug.Parsers with body_reader:")
               )
      end

      test "a Plug.Parsers whose options are not a keyword list is left alone" do
        source =
          String.replace(
            @endpoint_source,
            ~r/plug Plug\.Parsers,\s*parsers:[^\)]*\)/s,
            "plug Plug.Parsers, %{parsers: [:json]}"
          )

        assert source =~ "%{parsers:"

        igniter =
          Test.test_project(files: %{"lib/my_app_web/endpoint.ex" => source})
          |> Install.igniter()

        rendered = render(igniter, "lib/my_app_web/endpoint.ex")
        assert rendered =~ "Plug.Parsers"
        refute rendered =~ "body_reader"

        assert Enum.any?(
                 igniter.notices,
                 &String.contains?(&1, "Configure Plug.Parsers with body_reader:")
               )
      end

      test "a Plug.Parsers with no options is left alone (the manual step)" do
        source =
          String.replace(
            @endpoint_source,
            ~r/plug Plug\.Parsers,\s*parsers:[^\)]*\)/s,
            "plug Plug.Parsers"
          )

        # the surgical replace landed: exactly one bare Plug.Parsers plug remains
        assert source =~ "plug Plug.Parsers\n"

        igniter =
          Test.test_project(files: %{"lib/my_app_web/endpoint.ex" => source})
          |> Install.igniter()

        rendered = render(igniter, "lib/my_app_web/endpoint.ex")
        assert rendered =~ "Plug.Parsers"
        refute rendered =~ "body_reader"

        assert Enum.any?(
                 igniter.notices,
                 &String.contains?(&1, "Configure Plug.Parsers with body_reader:")
               )
      end
    end
  end
end
