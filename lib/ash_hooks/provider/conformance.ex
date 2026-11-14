defmodule AshHooks.Provider.Conformance do
  @moduledoc """
  An ExUnit case template for a provider's hand-written `decode_payload/2`.

  Use in a test module with `provider: YourProvider`. The generated test gives
  the provider a sentinel JSON decoder and asserts that its returned payload
  came from that decoder. A provider that calls `Jason.decode/1` directly fails.
  Providers extracting JSON from an envelope can supply `payload: verified_bytes`
  appropriate for their protocol. The default input is a JSON object.

  The template forwards ExUnit case options such as `:async` and `:register`.
  Passing checks the supplied payload path; exercise each supported envelope
  shape in your provider tests as well. ExUnit references expand only in the
  consumer's test module, so this module compiles without ExUnit on the code path.
  """

  @doc false
  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    payload = Keyword.get(opts, :payload, ~s({"input":"original"}))
    case_opts = Keyword.take(opts, [:async, :group, :parameterize, :register])

    quote do
      use ExUnit.Case, unquote(case_opts)

      test "provider decode_payload/2 uses the supplied JSON decoder" do
        sentinel = %{"decoder_sentinel" => make_ref()}
        decoder = fn _bytes -> {:ok, sentinel} end
        assert {:ok, ^sentinel} = unquote(provider).decode_payload(unquote(payload), decoder)
      end
    end
  end
end
