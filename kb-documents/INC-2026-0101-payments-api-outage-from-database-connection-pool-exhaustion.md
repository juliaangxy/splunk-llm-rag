# INC-2026-0101 — Payments API outage from database connection pool exhaustion

**Severity:** SEV1  |  **Status:** Resolved
**Opened:** 2026-01-14 08:42 UTC  |  **Resolved:** 2026-01-14 10:07 UTC  |  **Duration:** 1h 25m
**Services affected:** payments-api, checkout-web, ledger-service
**Detection:** Splunk alert 'payments-api 5xx rate > 5%' fired; PagerDuty paged the on-call SRE.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A traffic spike combined with a leaked connection in payments-api exhausted the PostgreSQL connection pool, causing checkout failures for ~18% of customers.

## Timeline
- **08:40** — Marketing email blast drives a 4x traffic spike to checkout.
- **08:42** — payments-api 5xx rate crosses 5%; Splunk alert fires.
- **08:51** — On-call confirms pool at max (200/200); new requests time out waiting for a connection.
- **09:15** — A code path added in release v3.8.1 found to not return connections on a retry branch.
- **09:40** — pgbouncer pool size raised 200 -> 400 as mitigation; error rate halves.
- **10:07** — Hotfix v3.8.2 deployed closing the leaked connections; error rate returns to baseline.

## Root cause
A retry branch introduced in v3.8.1 acquired a DB connection but returned early without releasing it, slowly exhausting the pool under load.

## Resolution
Deployed hotfix v3.8.2 to release connections on all branches; temporarily doubled the pgbouncer pool to absorb the spike.

## Impact
~18% of checkout attempts failed for 85 minutes; est. 2,400 abandoned carts.

## Action items
- Add a pool-utilization SLO alert at 80%.
- Add a lint/static-analysis rule for unreleased DB connections.
- Load-test release candidates at 5x baseline before promotion.

**Tags:** database, availability, payments, capacity
