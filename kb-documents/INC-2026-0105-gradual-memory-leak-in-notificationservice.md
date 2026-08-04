# INC-2026-0105 — Gradual memory leak in notification-service

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-03-18 06:30 UTC  |  **Resolved:** 2026-03-18 09:15 UTC  |  **Duration:** 2h 45m
**Services affected:** notification-service
**Detection:** Slow-burn alert: pod restarts every ~40 min; Splunk memory-trend panel flagged sawtooth pattern.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
An unbounded in-memory dedupe cache in notification-service leaked memory, causing periodic OOM restarts and delayed notifications.

## Timeline
- **06:30** — On-call notices notification-service restarting on a ~40-minute cadence.
- **07:10** — Heap dump shows the dedupe map growing without eviction.
- **08:20** — Mitigation: reduce cache TTL via config and scale out to 6 replicas.
- **09:15** — Fix released adding an LRU bound; restarts stop.

## Root cause
The dedupe cache had no size bound or TTL eviction, so entries accumulated until OOM.

## Resolution
Bounded the cache with an LRU policy and a 15-minute TTL; deployed and verified stable heap.

## Impact
Some notifications delayed up to 6 minutes over ~3 hours; no messages lost.

## Action items
- Add heap-growth alerting (sawtooth detection).
- Code review checklist item: all caches must be bounded.
- Add a soak test that runs 24h before release.

**Tags:** memory-leak, reliability, notifications
