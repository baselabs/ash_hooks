defmodule AshHooks.Test.SubscriptionPauseReceiver do
  @moduledoc false

  alias AshHooks.Http.Bounded

  def open! do
    root = "http://localhost:" <> System.get_env("ASH_HOOKS_REAL_RECEIVER_PORT", "52871")

    {:ok, %{status: 200}} =
      Bounded.request(:get, root <> "/api/version", %{}, "", validate_destination: false)

    {:ok, %{status: status, body: body}} =
      Bounded.request(
        :post,
        root <> "/api/session",
        %{"content-type" => "application/json"},
        Jason.encode!(%{status_code: 200}),
        validate_destination: false
      )

    true = status in 200..299
    id = Jason.decode!(body)["uuid"]
    %{root: root, id: id, url: root <> "/" <> id}
  end

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
        validate_destination: false
      )

    Jason.decode!(body)
  end
end
