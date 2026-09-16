# Upgrading

## 1.0.3 → next (unreleased)

Behavior corrections (all also under "Fixed" in the CHANGELOG; no API change):

### 1. Event ids and types are bounded by BYTES, not characters

`AshHooks.Event.new/1` and dispatch previously accepted ids and types up to
255 *characters* (graphemes). Long multi-byte values could pass that check
and then fail the delivery write — under Ash 3.33's `:codepoints` counting,
every endpoint's dispatch errored on an event the library had validated.
Ids and types are now rejected above 255 **bytes** at `Event.new/1`, with a
clear error. If you build event types from multi-byte text, values between
255 characters and 255 bytes now fail fast at construction — which, under
`:codepoints`, previously failed (less clearly) at dispatch.

### 2. Captured snippets and error fields are byte-capped

The 2048-character snippet cap and 255-character error-summary caps counted
graphemes; they now cap **bytes** (on a codepoint boundary). Captured
diagnostic snippets of multi-byte content come out slightly shorter, and a
hostile response body built from combining characters can no longer crash
the post-send ledger write — the same applies to thrown/exit error
classifications.

### 3. Handler failures with invalid-UTF-8 binaries still record

A handler returning `{:error, :retry | :permanent, term}` where `term` is
invalid UTF-8 previously made the failure-recording write itself fail, so
the delivery stayed re-drivable with no record. It now records `[binary]`
as the error class.

## Ash 3.33+: the required `default_string_length_count` config

Ash 3.33 made `config :ash, :default_string_length_count` REQUIRED for
every application that compiles Ash resources — resource compilation
fails until it is set. This is an Ash-level requirement (part of the fix
for GHSA-cwjv-574p-59f6, where grapheme-based counting let values built
from unbounded combining characters through `max_length` limits), not an
ash_hooks one; ash_hooks writes no `:ash` configuration for you. Set it
in your application's `config/config.exs`:

```elixir
# Recommended: counts unicode codepoints, so max_length bounds value
# size and validation matches how SQL data layers count.
config :ash, default_string_length_count: :codepoints

# Keeps pre-3.33 behavior: graphemes are counted when validating in
# Elixir; a single grapheme can carry unboundedly many codepoints, so
# max_length does not bound the size of a value.
config :ash, default_string_length_count: :mixed
```

ash_hooks works under both. One nuance worth knowing: the fields
ash_hooks injects onto ledger and delivery resources carry `max_length`
constraints (event ids and error summaries at 255, response snippets at
2048). Under `:codepoints` those bounds limit codepoints; under
`:mixed`, Elixir-side validation of the same constraints counts
graphemes — the exact tradeoff Ash documents for your own attributes.
The diagnostic response-snippet capture is capped in bytes (on a
codepoint boundary), so a captured snippet always satisfies its
constraint under either mode. Your application owns the choice. See
Ash's
[backwards-compatibility config guide](https://hexdocs.pm/ash/backwards-compatibility-config.html#default_string_length_count)
for per-attribute overrides.

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
