# INC-2026-0115 — Redis cache stampede after a mass key expiry

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-07-08 11:40 UTC  |  **Resolved:** 2026-07-08 12:35 UTC  |  **Duration:** 0h 55m
**Services affected:** catalog-service, redis-cache, primary-db
**Detection:** DB CPU saturation + cache-miss spike; Splunk correlation of TTL expiry and DB load.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A batch job set identical TTLs on millions of keys; simultaneous expiry caused a thundering herd of cache misses that overloaded the primary database.

## Timeline
- **11:30** — Nightly warmup writes 3M keys with the same 12h TTL.
- **11:40** — All keys expire together; cache-miss rate spikes; DB CPU hits 100%.
- **12:05** — Request coalescing enabled; DB read replicas scaled up.
- **12:35** — Cache refilled with jittered TTLs; DB load normal.

## Root cause
Uniform TTLs caused synchronized expiry (a cache stampede) with no request coalescing / mutex.

## Resolution
Added TTL jitter, single-flight request coalescing, and stale-while-revalidate on hot keys.

## Impact
Elevated latency and some timeouts for ~55 minutes.

## Action items
- Always jitter TTLs on bulk cache writes.
- Implement single-flight for hot keys.
- Add DB CPU + cache-miss correlation alert.

**Tags:** cache, redis, database, performance
