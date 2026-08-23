# Upgrading

## 1.0.1 → 1.0.2+

Two behavior corrections to know about (both security-posture fixes; no API change):

### 1. The alternate `:httpc` adapter refuses literal-IP HTTPS

`AshHooks.Http.Httpc` (NOT the default) now returns `{:error, :ip_literal_https_needs_bounded}`
for `https://<ip-literal>` destinations. It previously validated only the chain — which let
any chain-valid certificate authenticate the endpoint IP. The default adapter
(`AshHooks.Http.Bounded`) enforces the iPAddress-SAN floor and keeps working; if you swapped
to `:httpc` AND deliver to literal-IP HTTPS endpoints, switch those deliveries back (or drop
the `:http` override).

### 2. `use AshHooks.Worker` no longer drops `:http_opts`

`http_opts:` was accepted and silently ignored; it now threads to the adapter. A config that
passed it with a wrong shape could start behaving differently (correctly) — see the `:cacerts`
seam in the README/CHANGELOG for the intended use (private-CA bundles: compile-time literals,
or `{m, f, a}` resolved per-perform for computed values).

## 0.2.x → 1.0.0

1.0.0 is the semver freeze (ADR-0010). There are **no public API removals or renames**
from 0.2.x — upgrading is a version bump plus three behavior corrections to know about:

### 1. Truncated chunked bodies now retry (they previously "succeeded")

`AshHooks.Http.Bounded` (the default adapter) returns `{:error, :truncated_body}` when a
chunked response ends early — exactly as it already did for Content-Length responses. In
0.2.x the chunked path returned a partial body as success, which could mark a delivery
`:succeeded` on partial bytes. If a receiver of yours streams chunked responses and
closes mid-body, deliveries now retry instead of silently truncating.

### 2. `AshHooks.Delivery.prune/2` returns `{:error, error}` instead of raising

Calling it on a delivery resource without `inserted_at` now returns the same error-tuple
contract as `AshHooks.Ingress.prune/2` (the `@spec` always promised this shape). If you
rescued the old `ArgumentError`, replace it with an `{:error, error}` match.

### 3. Literal-IP https endpoints actually work now

The literal-IP certificate check (IP must appear in the certificate's iPAddress SAN,
ADR-0009) was dead-on-arrival in 0.2.x — it rejected **every** literal-IP https endpoint
fail-closed with `:cert_ip_mismatch`. It now verifies correctly: endpoints whose certs
carry the IP SAN deliver; certs without it still fail closed. No action needed unless
you had worked around the rejection.

### Install constraint

```elixir
{:ash_hooks, "~> 1.0"}
```

### Semver from here

`~> 1.0` now means: breaking changes only in 2.0, deprecations run two minors minimum,
safety corrections ship as fixes even where the defective behavior was depended on
(ADR-0010).
