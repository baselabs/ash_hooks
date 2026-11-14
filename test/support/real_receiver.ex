defmodule AshHooks.Test.RealReceiver do
  @moduledoc false
  # Client for the real HTTP receiver that `:real_receiver` tests deliver to
  # (its port in ASH_HOOKS_REAL_RECEIVER_PORT). A session is one receiving URL
  # that answers with a configured response and records what it received.
  #
  # Every call for a session uses the host the session was opened with, so
  # control calls and deliveries reach the same listener. Endpoints created
  # through package actions need `localhost` (registration refuses loopback
  # literals); tests that set endpoint URLs directly may use `127.0.0.1`.

  alias AshHooks.Http.Bounded

  # Options: `:host` (default "localhost"), `:status` (default 200),
  # `:headers` (name to value), `:delay` (seconds before answering) and
  # `:body` (response bytes).
  def open!(opts \\ []) do
    port = System.get_env("ASH_HOOKS_REAL_RECEIVER_PORT", "52871")
    root = "http://" <> Keyword.get(opts, :host, "localhost") <> ":" <> port

    response =
      Jason.encode!(%{
        "status_code" => Keyword.get(opts, :status, 200),
        "headers" =>
          opts
          |> Keyword.get(:headers, %{})
          |> Enum.map(fn {name, value} -> %{"name" => name, "value" => value} end),
        "delay" => Keyword.get(opts, :delay, 0),
        "response_body_base64" => Base.encode64(Keyword.get(opts, :body, ""))
      })

    {:ok, %{status: status, body: body}} =
      Bounded.request(
        :post,
        root <> "/api/session",
        %{"content-type" => "application/json"},
        response,
        validate_destination: false,
        max_body_bytes: 65_536
      )

    true = status in 200..299
    %{root: root, id: Jason.decode!(body)["uuid"]}
  end

  def url(%{root: root, id: id}), do: root <> "/" <> id

  def close!(%{root: root, id: id}) do
    {:ok, %{status: status}} =
      Bounded.request(:delete, root <> "/api/session/" <> id, %{}, "",
        validate_destination: false
      )

    true = status in 200..299
    :ok
  end

  def requests!(%{root: root, id: id}) do
    {:ok, %{status: 200, body: body}} =
      Bounded.request(:get, root <> "/api/session/" <> id <> "/requests", %{}, "",
        validate_destination: false,
        max_body_bytes: 1_048_576
      )

    Jason.decode!(body)
  end
end
