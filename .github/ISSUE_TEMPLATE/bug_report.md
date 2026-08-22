---
name: Bug report
about: Something behaves wrong or unsafely
title: ""
labels: bug
assignees: ""
---

**What happened** — the observed behavior, and the error/output if any.

**What did you expect?**

**Which side?** inbound (receive/verify/dedup) or outbound (sign/deliver/retry)?

**Environment**
- ash_hooks version:
- Ash version:
- Elixir / OTP:
- Data layer: ash_postgres / ash_sqlite / other:

**Reproduction** — the smallest resource/DSL snippet + payload that shows it. For
verification bugs: name the provider and link the vendor's signing docs page you
verified against. **Never paste real secrets or signed payloads from production** —
synthesize the smallest bytes that reproduce.

For security reports, do NOT open an issue — see SECURITY.md.
