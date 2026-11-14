defmodule AshHooks.Custody.Fingerprint do
  @moduledoc false

  def digest({:standard_webhooks, version}, bytes) when version in [:v1, :v1a] do
    :crypto.hash(
      :sha256,
      "ash_hooks key fingerprint v1\0standard_webhooks.#{version}\0" <> bytes
    )
    |> binary_part(0, 16)
  end

  def display(<<_::128>> = digest), do: "SHA256:" <> Base.url_encode64(digest, padding: false)
end
