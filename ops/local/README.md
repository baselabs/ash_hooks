# Local operations

Local signing/transport inspection for the `ash_hooks` package against the
machine-local WebHook-Tester inbox. One run exercises the full public loop this
package exists for: `AshHooks.Signing.generate_secret/0`, `AshHooks.Signing.headers/4`,
an `AshHooks.Http.Bounded.request/5` POST, the receiver's captured copy read back
through the bounded client, and `AshHooks.Signing.verify/3` over the exact captured
bytes and headers. It starts no application, uses no database, dispatches no
delivery, and changes no endpoint registration.

## Receiver

`webhook-tester.compose.yaml` pins the image by digest, binds `127.0.0.1:52871`,
keeps `restart: always` and the named capture volume `local-webhook-tester-captures`
(seven-day session TTL, 1,000 requests per session). Where another baselabs
repository already runs this exact receiver, USE THE RUNNING ONE — check it
without restarting:

```sh
docker compose -f ops/local/webhook-tester.compose.yaml ps
```

Create it only on a fresh machine:

```sh
docker compose -f ops/local/webhook-tester.compose.yaml up -d
```

Never delete the named capture volume to "restart" the service.

## Send and verify

From the repository root, on the pinned Elixir/OTP toolchain (`MIX_ENV=dev` is
the default for `elixir` runs; set it explicitly when your shell exports another):

```sh
MIX_ENV=dev elixir ops/local/send-webhook.exs
# Or send the exact bytes of a local file:
MIX_ENV=dev elixir ops/local/send-webhook.exs /path/to/payload.json
```

Each run opens a FRESH receiver session (auto-created on first POST) and signs
with an EPHEMERAL key that is never persisted or printed. A passing run ends with
`PASS: captured payload and signature verified (msg_...)` and prints the session's
inbox URL. Use development payloads: captures are retained in the local Docker
volume.
