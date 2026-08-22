defmodule AshHooks.HttpTest do
  @moduledoc """
  The default `:httpc` adapter's SHAPE contract (the live send path is
  proven by the runtime smoke — the suite's adapter coverage is the
  double). Direct adapter calls are not subject to the SSRF guard, so a
  refused local port pins the no-crash error contract here.
  """

  use ExUnit.Case, async: true

  alias AshHooks.Http.Httpc

  test "a refused connection is an error tuple, never a raise" do
    assert {:error, _reason} =
             Httpc.request(
               :post,
               "https://127.0.0.1:1/hook",
               %{"content-type" => "application/json"},
               "{}"
             )
  end

  test "a garbage url is an error tuple, never a raise" do
    assert {:error, _reason} = Httpc.request(:post, "not a url", %{}, "{}")
  end
end
