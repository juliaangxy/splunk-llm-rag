# INC-2026-0111 — Splunk indexer cluster stopped ingesting after disks filled

**Severity:** SEV1  |  **Status:** Resolved
**Opened:** 2026-05-25 03:10 UTC  |  **Resolved:** 2026-05-25 05:35 UTC  |  **Duration:** 2h 25m
**Services affected:** splunk-indexer-cluster, log-ingest
**Detection:** Indexer 'queues blocked' + volume usage 100%; forwarder connection drops observed.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A misconfigured index with no retention cap filled the hot volume on three indexers, blocking ingest queues and creating a logging blind spot.

## Timeline
- **02:40** — A new high-volume index is created without size/time retention limits.
- **03:10** — Hot volume reaches 100% on 3 indexers; queues block; forwarders back up.
- **03:55** — Frozen/rolled old buckets manually; raised maxTotalDataSizeMB on the offending index.
- **05:35** — Ingest resumes; forwarder backlog drains.

## Root cause
The new index had no maxTotalDataSizeMB or frozenTimePeriodInSecs, so it grew until the volume was full.

## Resolution
Applied retention limits, rolled buckets to frozen, and added volume-based limits at the volume level.

## Impact
~2.5h of delayed/blocked log ingest; some source data buffered on forwarders and recovered.

## Action items
- Require retention settings on all new indexes (config lint).
- Alert at 80% volume utilization.
- Set volume-level maxVolumeDataSizeMB as a backstop.

**Tags:** splunk, logging, capacity, reliability
