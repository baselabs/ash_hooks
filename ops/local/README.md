# Local operations

Local signing/transport inspection for the `ash_hooks` package against the
machine-local WebHook-Tester inbox. One run exercises the full public loop this
package exists for: `AshHooks.Signing.generate_secret/0`, `AshHooks.Signing.headers/4`,
an `AshHooks.Http.Bounded.request/5` POST, the receiver's captured copy read back
through the bounded client, and `AshHooks.Signing.verify/3` over the exact captured
bytes and headers. It starts no application, uses no database, dispatches no
delivery, and changes no endpoint registration.

## Receiver

These checks require a WebHook Tester receiver. First probe an existing service
at `127.0.0.1:52871`; CI runs one beside PostgreSQL:

```sh
curl -fsS http://127.0.0.1:52871/api/version
```

For first-time setup, install Docker with Compose and run from the repository
root using the tracked [Compose definition](webhook-tester.compose.yaml):

```sh
docker compose -f ops/local/webhook-tester.compose.yaml up -d
curl -fsS http://127.0.0.1:52871/api/version
```

The default loopback port is 52871. To choose a free port before the first start:

```sh
LOCAL_WEBHOOK_TESTER_PORT=37524 docker compose -f ops/local/webhook-tester.compose.yaml up -d
curl -fsS http://127.0.0.1:37524/api/version
```

Set that same `LOCAL_WEBHOOK_TESTER_PORT` for the inspection script or notebook,
and `ASH_HOOKS_REAL_RECEIVER_PORT` for tests. Reuse an existing service rather
than starting a second receiver. If an owned receiver stops answering, inspect
its Compose logs before restarting it. Never restart another user's receiver or
delete its capture volume to recover it. The inspection scripts start no server.

## Send and verify

From the repository root, on the pinned Elixir/OTP toolchain (`MIX_ENV=dev` is
the default for `elixir` runs; set it explicitly when your shell exports another):

```sh
MIX_ENV=dev elixir ops/local/send-webhook.exs
# Or send the exact bytes of a local file:
MIX_ENV=dev elixir ops/local/send-webhook.exs /path/to/payload.json
```

To use an existing sanctioned receiver on another loopback port, set
`LOCAL_WEBHOOK_TESTER_PORT` for that command; the default is 52871:

```sh
LOCAL_WEBHOOK_TESTER_PORT=37524 MIX_ENV=dev elixir ops/local/send-webhook.exs
```

Each run opens a FRESH receiver session (auto-created on first POST) and signs
with an EPHEMERAL key that is never persisted or printed. A passing run ends with
`PASS: captured payload and signature verified (msg_...)` and prints the session's
inbox URL. Use development payloads: the receiver retains captured requests
according to its configured storage and session TTL.
