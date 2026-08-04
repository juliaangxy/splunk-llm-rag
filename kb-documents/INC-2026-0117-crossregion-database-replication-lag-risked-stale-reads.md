# INC-2026-0117 — Cross-region database replication lag risked stale reads

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-07-30 16:20 UTC  |  **Resolved:** 2026-07-30 17:45 UTC  |  **Duration:** 1h 25m
**Services affected:** user-profile-db, read-replicas (eu-west-1)
**Detection:** Replica lag > 90s alert; Splunk showed EU read-after-write inconsistencies.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A large backfill on the primary saturated replication to the EU region, so EU users occasionally saw stale profile data right after updates.

## Timeline
- **16:00** — A one-off backfill updates 40M rows on the primary.
- **16:20** — EU replica lag exceeds 90s; stale-read reports arrive.
- **16:55** — Backfill throttled to smaller batches; app pinned recent writers to the primary.
- **17:45** — Replica lag < 2s; consistency restored.

## Root cause
An unthrottled bulk update generated more WAL than cross-region replication could apply in real time.

## Resolution
Throttled the backfill into small batches, added read-your-writes routing, and paused non-critical replicas.

## Impact
Occasional stale reads for EU users for ~1.5h; no data loss or corruption.

## Action items
- Throttle and schedule bulk writes.
- Add read-your-writes routing for recent writers.
- Alert on replica lag with regional context.

**Tags:** database, replication, consistency, multi-region
