# INC-2026-0103 — Volumetric DDoS against the API gateway

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-02-19 13:20 UTC  |  **Resolved:** 2026-02-19 15:05 UTC  |  **Duration:** 1h 45m
**Services affected:** api-gateway, auth-service
**Detection:** Sudden 30x request-rate spike from a narrow ASN range; Splunk traffic-anomaly alert.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A layer-7 HTTP flood targeting the login endpoint degraded API latency for legitimate users.

## Timeline
- **13:18** — Inbound request rate jumps from 4k to 120k rps against /auth/login.
- **13:20** — Traffic-anomaly alert fires; latency p95 climbs to 8s.
- **13:35** — WAF rate-based rule enabled for /auth/*; bot traffic partially blocked.
- **14:10** — AWS Shield/managed rules tuned to the offending fingerprints and ASNs.
- **15:05** — Traffic normalizes; latency back to p95 220ms.

## Root cause
An external botnet ran a credential-stuffing flood against the login endpoint; the gateway had no per-IP or per-path rate limiting on auth routes.

## Resolution
Enabled WAF rate-based rules on auth paths, added ASN/fingerprint blocks, and turned on challenge responses.

## Impact
Elevated latency and intermittent 429s for ~1h45m; no data breach; no successful account takeover.

## Action items
- Make rate limiting default on all auth endpoints.
- Add a runbook for enabling WAF challenge mode.
- Ship a Splunk dashboard for auth-endpoint request fingerprints.

**Tags:** security, ddos, waf, availability
