# INC-2026-0108 — Kafka consumer lag delayed the analytics pipeline

**Severity:** SEV3  |  **Status:** Resolved
**Opened:** 2026-04-16 22:05 UTC  |  **Resolved:** 2026-04-17 00:20 UTC  |  **Duration:** 2h 15m
**Services affected:** events-pipeline, analytics-warehouse
**Detection:** Consumer-group lag exceeded 2M messages; Splunk lag dashboard alert.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A slow downstream write to the warehouse caused the analytics consumer group to fall behind, delaying dashboards but not losing data.

## Timeline
- **21:50** — A warehouse index rebuild slows batch inserts.
- **22:05** — Consumer lag crosses 2M; alert fires.
- **23:00** — Consumers scaled 4 -> 12; batch size tuned down.
- **00:20** — Lag drains to < 50k; pipeline caught up.

## Root cause
A scheduled warehouse index rebuild throttled inserts, back-pressuring the Kafka consumers.

## Resolution
Scaled out consumers and reduced batch size until lag drained; rescheduled the rebuild to a low-traffic window.

## Impact
Analytics dashboards delayed up to ~2 hours; no event loss.

## Action items
- Schedule warehouse maintenance in off-peak windows.
- Autoscale consumers on lag.
- Separate maintenance from ingest partitions.

**Tags:** kafka, data-pipeline, latency
