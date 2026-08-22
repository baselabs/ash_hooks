# Upgrading

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
