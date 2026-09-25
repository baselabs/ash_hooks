# Local signing/transport inspection for the ash_hooks package itself.
# Run from the repository root:  MIX_ENV=dev elixir ops/local/send-webhook.exs
# Or send the exact contents of a local payload file:
#   MIX_ENV=dev elixir ops/local/send-webhook.exs /path/to/payload.json
Mix.start()
unless Mix.env() == :dev, do: raise("local webhook inspection requires MIX_ENV=dev")

root = Path.expand("../..", __DIR__)

Mix.Project.in_project(:ash_hooks, root, fn _ ->
  Mix.Task.run("loadconfig")
  Mix.Task.run("compile")
end)

{:ok, _} = Application.ensure_all_started(:crypto)
base = "http://127.0.0.1:52871"

# Fresh receiver session per run (AUTO_CREATE_SESSIONS creates it on first POST);
# no shared inbox state with any other repository's dedicated session. Version-4
# and variant bits are forced at the byte level, keeping the 8-4-4-4-12 shape the
# receiver validates.
import Bitwise

<<g1::binary-size(4), b4, b5, g3::binary-size(2), b8, b9, g5::binary-size(6)>> =
  :crypto.strong_rand_bytes(16)

session =
  Base.encode16(g1, case: :lower) <> "-" <>
    Base.encode16(<<0x40 ||| band(b4, 0x0F), b5>>, case: :lower) <> "-" <>
    Base.encode16(g3, case: :lower) <> "-" <>
    Base.encode16(<<0x80 ||| band(b8, 0x3F), b9>>, case: :lower) <> "-" <>
    Base.encode16(g5, case: :lower)
url = base <> "/" <> session

payload =
  case System.argv() do
    [] -> Jason.encode!(%{type: "local.signing_probe", repo: "ash_hooks", sent_at: DateTime.utc_now()})
    [path] -> File.read!(path)
    _ -> raise "usage: MIX_ENV=dev elixir ops/local/send-webhook.exs [payload-file]"
  end

# Ephemeral inspection key: never persisted or printed, never production custody.
secret = AshHooks.Signing.generate_secret()
id = "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
headers = AshHooks.Signing.headers(id, System.system_time(:second), payload, whsec: secret)

# This standalone dev command has one literal loopback destination. It does not
# change application configuration or relax endpoint registration/worker checks.
{:ok, %{status: 200}} =
  AshHooks.Http.Bounded.request(:post, url, headers, payload, validate_destination: false)

{:ok, %{status: 200, body: body}} =
  AshHooks.Http.Bounded.request(:get, base <> "/api/session/" <> session <> "/requests", %{}, "",
    validate_destination: false,
    max_body_bytes: 8_388_608
  )

capture =
  body
  |> Jason.decode!()
  |> Enum.find(fn request ->
    Enum.any?(request["headers"], fn header ->
      String.downcase(header["name"]) == "webhook-id" and header["value"] == id
    end)
  end)

unless capture, do: raise("receiver did not retain this webhook")
^payload = Base.decode64!(capture["request_payload_base64"])

captured_headers =
  Map.new(capture["headers"], &{String.downcase(&1["name"]), &1["value"]})

{:ok, %{id: ^id}} = AshHooks.Signing.verify(payload, captured_headers, secret)
IO.puts("PASS: captured payload and signature verified (#{id})")
IO.puts("Inbox: http://localhost:52871/s/#{session}")
