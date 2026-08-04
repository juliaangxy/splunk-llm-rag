# INC-2026-0107 — DNS misconfiguration black-holed internal service discovery

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-04-05 15:22 UTC  |  **Resolved:** 2026-04-05 16:10 UTC  |  **Duration:** 0h 48m
**Services affected:** service-mesh, orders-service, inventory-service
**Detection:** Spike in NXDOMAIN resolver errors in Splunk; dependent services returning 503.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A bad private hosted-zone change removed A records for internal service names, breaking east-west traffic across the mesh.

## Timeline
- **15:20** — A Route53 automation prunes 'stale' records but matches a live wildcard.
- **15:22** — NXDOMAIN errors spike; orders-service can't resolve inventory-service.
- **15:45** — Change identified via CloudTrail; records restored from the prior zone export.
- **16:10** — Resolution caches warm; error rate returns to zero.

## Root cause
A cleanup script's match pattern was too broad and deleted active internal DNS records.

## Resolution
Restored records from the last hosted-zone export and disabled the cleanup automation pending a fix.

## Impact
Intermittent internal 503s for ~48 minutes; customer impact limited by retries and caches.

## Action items
- Dry-run + human approval for any DNS deletion automation.
- Back up hosted zones on every change.
- Add NXDOMAIN-rate alerting per resolver.

**Tags:** dns, networking, reliability
