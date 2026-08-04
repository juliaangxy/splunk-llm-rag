# INC-2026-0118 — Log-ingestion pipeline dropped events, creating a monitoring blind spot

**Severity:** SEV1  |  **Status:** Resolved
**Opened:** 2026-08-11 04:50 UTC  |  **Resolved:** 2026-08-11 07:10 UTC  |  **Duration:** 2h 20m
**Services affected:** log-forwarder, ingest-pipeline, splunk-hec
**Detection:** Sudden drop in indexed event volume; Splunk 'events per minute below floor' alert.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
An HEC token change wasn't propagated to forwarders, so a large fraction of events were rejected and silently dropped, leaving gaps in dashboards and alerts.

## Timeline
- **04:30** — HEC token rotated on the indexers; forwarder config not updated.
- **04:50** — Indexed volume drops ~60%; below-floor alert fires.
- **05:30** — 403 'invalid token' found in forwarder logs; root cause identified.
- **06:20** — New token rolled to all forwarders; buffered events replayed where possible.
- **07:10** — Event volume back to baseline; gap documented for the affected window.

## Root cause
HEC token rotation was applied on the receiver side only; forwarders kept sending the old token and were rejected.

## Resolution
Distributed the new token to all forwarders via config management and replayed buffered events.

## Impact
~60% event loss for parts of a 2h20m window; some alerts did not fire during the gap.

## Action items
- Coordinate HEC token rotation across senders and receivers atomically.
- Alert on ingest volume anomalies (floor + delta).
- Enable forwarder-side persistent queues to survive rejections.

**Tags:** splunk, logging, hec, blind-spot
