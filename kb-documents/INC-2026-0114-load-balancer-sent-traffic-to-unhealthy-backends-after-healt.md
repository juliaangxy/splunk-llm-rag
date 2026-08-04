# INC-2026-0114 — Load balancer sent traffic to unhealthy backends after health-check change

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-06-28 20:15 UTC  |  **Resolved:** 2026-06-28 21:00 UTC  |  **Duration:** 0h 45m
**Services affected:** api-gateway, user-service
**Detection:** Elevated 502s at the ALB; Splunk target-health panel showed flapping targets marked healthy.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A health-check path change pointed at an endpoint that always returned 200 even when the app was not ready, so the ALB routed traffic to unready instances.

## Timeline
- **20:10** — Health check path changed from /readyz to / to 'reduce noise'.
- **20:15** — New instances marked healthy before app warm-up; 502s spike.
- **20:35** — Reverted health check to /readyz with proper dependency checks.
- **21:00** — Targets stabilize; 502s clear.

## Root cause
The health-check endpoint no longer reflected true readiness, so the LB advertised unready targets.

## Resolution
Restored a readiness endpoint that validates dependencies and warm-up before returning 200.

## Impact
Intermittent 502s during scaling events for ~45 minutes.

## Action items
- Standardize /readyz vs /livez semantics across services.
- Block health-check changes without a readiness contract test.
- Add target-health flapping alerts.

**Tags:** load-balancer, health-checks, reliability
