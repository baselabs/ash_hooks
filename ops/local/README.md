# Local operations

Local signing/transport inspection for the `ash_hooks` package against the
machine-local WebHook-Tester inbox. One run exercises the full public loop this
package exists for: `AshHooks.Signing.generate_secret/0`, `AshHooks.Signing.headers/4`,
an `AshHooks.Http.Bounded.request/5` POST, the receiver's captured copy read back
through the bounded client, and `AshHooks.Signing.verify/3` over the exact captured
bytes and headers. It starts no application, uses no database, dispatches no
delivery, and changes no endpoint registration.

## Receiver

These checks use a WebHook Tester receiver that is already running on
`127.0.0.1:52871` (CI runs one beside its PostgreSQL service). Check it without
restarting anything; it answers with its version:

```sh
curl -fsS http://127.0.0.1:52871/api/version
```

If the version probe fails, bring your receiver back before running anything
here; these scripts never start one. Never delete the receiver's capture volume
to "restart" it.

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
