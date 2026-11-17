# 0027: Observation read failures

Status: Accepted November 16, 2026.

## Context

`Ingress.counts/2` and `EndpointHealth.sweep/3` read stored observations: ledger
rows and attempt history. Each turns what it reads into a result that hosts act on
(ADR 0019, ADR 0020). If a read failure is reported as "no observations", a host
cannot tell an outage from a quiet period, and a health sweep can miss an endpoint
without saying so.

## Decision

A failed observation read is reported, never counted as zero.

- **`Ingress.counts/2`** computes its counts in the data layer, with count and sum
  queries over the window. It never loads rows to count them. If any of those reads
  fails, it returns `{:error, reason}`.
- **`EndpointHealth.sweep/3`** reads every enabled endpoint. If one endpoint's
  attempt-history read fails, the sweep still checks the other endpoints. That
  endpoint is not warned, disabled or cleared. The sweep counts it in an `unread`
  field of its result and emits
  `[:ash_hooks, :endpoint_health, :read_failed]` with the endpoint and the reason.
  A failed read of the endpoint list fails the whole sweep.

## Consequences

Hosts can alert on observation outages. An endpoint whose history cannot be read
keeps its current health state until a later sweep reads it. Adding the `unread`
key to the sweep's result is an additive change.
