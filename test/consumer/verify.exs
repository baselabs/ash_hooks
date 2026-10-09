version = Application.spec(:ash_hooks, :vsn) |> to_string()

# The expected version is the checkout's own @version — no per-release pin to drift.
root = Path.expand("../..")

expected =
  root
  |> Path.join("mix.exs")
  |> File.read!()
  |> then(&Regex.run(~r/@version "([^"]+)"/, &1))
  |> Enum.at(1)

unless version == expected,
  do: raise("unexpected consumer build version: #{version} != #{expected}")

applications = Application.started_applications() |> Enum.map(&elem(&1, 0))

for required <- [:crypto, :public_key, :ssl, :inets] do
  unless required in applications, do: raise("required OTP application not started: #{required}")
end

for optional <- [Oban, Plug] do
  unless :code.which(optional) == :non_existing,
    do: raise("optional dependency present in minimal consumer")
end

Code.ensure_loaded!(Ash.Resource.Info)

unless function_exported?(Ash.Resource.Info, :multitenancy_tenant_from_attribute, 1),
  do: raise("required minimum Ash API absent")

secret = AshHooks.Signing.generate_secret()
payload = Jason.encode!(%{kind: "consumer_verification", at: DateTime.utc_now()})
{:ok, event} = AshHooks.Event.new(type: :consumer_verification, payload: payload)
headers = AshHooks.Signing.headers(event.id, System.system_time(:second), payload, whsec: secret)
{:ok, %{id: verified_id}} = AshHooks.Signing.verify(payload, headers, secret)
unless verified_id == event.id, do: raise("signature identity mismatch")

{private_key, public_key} = AshHooks.Signing.generate_signing_keypair()

asymmetric_headers =
  AshHooks.Signing.headers(event.id, System.system_time(:second), payload, whsk: private_key)

{:ok, %{id: asymmetric_id}} = AshHooks.Signing.verify(payload, asymmetric_headers, public_key)
unless asymmetric_id == event.id, do: raise("asymmetric signature identity mismatch")

{:error, :invalid_signature} =
  AshHooks.Signing.verify(payload <> "tampered", asymmetric_headers, public_key)

{:ok, %{status: 200, body: body}} =
  AshHooks.Http.Bounded.request(
    :get,
    "https://hex.pm/api/packages/ash_hooks",
    %{"user-agent" => "ash_hooks-consumer-verification/#{version}"},
    "",
    max_body_bytes: 1_024,
    timeout: 10_000
  )

unless byte_size(body) > 0 and byte_size(body) <= 1_024, do: raise("unexpected HTTP response cap")

{:ok, %{status: 200, body: httpc_body}} =
  AshHooks.Http.Httpc.request(
    :get,
    "https://hex.pm/api/packages/ash_hooks",
    %{"user-agent" => "ash_hooks-consumer-verification/#{version}"},
    "",
    max_body_bytes: 1_024,
    timeout: 10_000
  )

unless byte_size(httpc_body) > 0 and byte_size(httpc_body) <= 1_024,
  do: raise("unexpected Httpc response cap")

IO.puts(
  "CONSUMER OK: ash_hooks #{version}; Ash #{Application.spec(:ash, :vsn)}; OTP apps started; optional deps absent; HMAC and Ed25519 verified; Ed25519 tampering rejected; Bounded and Httpc HTTPS returned 200"
)
