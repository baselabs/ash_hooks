# ADR-0009 — Bounded HTTP adapter as default, and the SSRF pinning substrate

- **Status:** Accepted (2026-08-22) — consolidates the derisk-1/derisk-2 decisions that
  previously lived only in moduledocs and session records; supersedes ADR-0007's interim
  ":httpc default" record (the spec's original `:httpc` line was never amended when the
  default flipped).
- **Deciders:** maintainer; cross-vendor findings folded in (pinned-IP TLS, truncated-body
  classification, chunk-size buffering)

## Context

The outbound delivery runtime speaks HTTP through a one-callback behaviour
(`AshHooks.Http.request/5`). Two silent failure classes live at that boundary: memory
denial-of-service (a hostile receiver answering with a giant body balloons a delivery
worker's heap) and SSRF (a webhook URL aimed at cloud metadata / loopback / private
ranges, including DNS-rebinding: validate-then-resolve-again TOCTOU). The original
`:httpc` adapter bounds neither tightly — `:httpc` streams only 200/206 responses, so a
giant NON-2xx body assembles whole before any package-level cut, and its redirect
handling would re-issue POST as GET.

## Decision

1. **`AshHooks.Http.Bounded` is the default adapter** (`config[:http] ||
   AshHooks.Http.Bounded` in `AshHooks.Delivery`): a minimal HTTP/1.1 client over
   `:gen_tcp`/`:ssl` with hard caps on every framing — header block ≤ 32 KiB, body ≤
   64 KiB under Content-Length, chunked, and read-to-close alike; connect 5s / receive
   15s; one request per connection, `Connection: close`, **no redirects ever** (a 3xx
   surfaces as a response the runtime dead-letters as a refused redirect). Chunk-size
   declarations are attacker-controlled and never buffered toward (phase-bounded
   keep/discard/verify; probe 2026-08-22: 235KB peak against an 8MB declaration that
   previously held 16.8MB). `AshHooks.Http.Httpc` remains available via the worker's
   `:http` opt. Its residual window — `:httpc` streams only 200/206, so a giant
   NON-2xx body assembles whole inside OTP before the package cut — is MEASURED, not
   just documented (dribble probe 2026-08-22, 4MB error body against a 16-byte
   bound): ~4.65MB transient (≈1.16× the body), final body cut to the bound; the
   committed containment test pins the cut (`test/ash_hooks/http_test.exs`, "a giant
   NON-2xx body is still CUT at the bound").
2. **Truncated responses never classify as success**: a Content-Length or chunked body
   cut by early close is `{:error, :truncated_body}` (aligned across framings
   2026-08-22 — the chunked path previously returned a partial `{:ok, ...}`). The
   driver retries truncated bodies; a 2xx on partial bytes must never mark a delivery
   succeeded. Read-to-close framing has no early end by definition.
3. **SSRF enforced twice** (ADR-0005): at endpoint registration (scheme, literal IPs,
   metadata/private/link-local hostnames — deliberately offline-safe) and at send time
   (`AshHooks.Ssrf.resolve_public/1`: full dual-family DNS resolution, fail-closed on
   unresolvable, every answer public, IPv4-mapped/compat/6to4/Teredo/NAT64 unwrapped).
4. **Pinned-IP connection closes the rebinding TOCTOU**: `AshHooks.Http.Target` resolves
   once; the adapter connects to the VALIDATED address while TLS (SNI + RFC 6125) and
   the `host` header name the ORIGINAL host. For literal-IP https destinations — no
   name to check — the peer cert must carry the exact IP in its `iPAddress` SAN
   (`AshHooks.Http.CertSan`; chain validation alone would accept ANY publicly-trusted
   cert for the IP). Found dead-on-arrival 2026-08-22 (dialyzer: the matcher was
   unreachable since birth) and fixed with fixture-tested extraction — every literal-IP
   https endpoint had been rejected fail-closed.

## Consequences

- No receiver — hostile or merely buggy — can balloon a worker's memory through the
  default adapter; every bound is opt-overridable for known-large legitimate bodies.
- No redirect-following means no redirect-based SSRF chain; receivers that require
  redirect support must opt into a custom adapter consciously.
- The bounded adapter speaks exactly what the delivery runtime sends (subset of
  HTTP/1.1) — exotic server behaviors outside that subset surface as errors, not
  surprises.
- Certificates for literal-IP endpoints must carry the iPAddress SAN (or the endpoint
  dead-letters with `:cert_ip_mismatch`) — compliant with how modern CAs issue IP certs.
- Trust-store injection (D3, 2026-08-22): `Target.ssl_options/2` and both adapters take
  an injectable `:cacerts` bundle (adapter opts; worker `:http_opts`) for private-CA
  endpoints — default unchanged, the OTP CA store. The alternate `:httpc` adapter
  refuses literal-IP HTTPS fail-closed instead: it cannot run the IP-SAN floor.
