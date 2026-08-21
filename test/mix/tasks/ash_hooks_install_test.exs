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
      # igniter normalizes `plug X` to `plug(X)` — match on the call, not the
      # exact formatting
      assert content =~ "plug(Plug.RequestId)"
      assert content =~ "json_decoder: Phoenix.json_library()"
    end

    test "is idempotent — running twice adds the option once" do
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
    end

    defp render(igniter, path) do
      igniter.rewrite |> Rewrite.source!(path) |> Source.get(:content)
    end
  end
end
