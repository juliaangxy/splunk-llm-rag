# INC-2026-0102 — Public site outage due to expired TLS certificate

**Severity:** SEV1  |  **Status:** Resolved
**Opened:** 2026-02-03 00:04 UTC  |  **Resolved:** 2026-02-03 01:12 UTC  |  **Duration:** 1h 08m
**Services affected:** www-frontend, api-gateway
**Detection:** Synthetic monitor reported TLS handshake failures; Splunk alert on cert-expiry dashboard.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
The wildcard TLS certificate for *.example.com expired because auto-renewal had been silently failing for 27 days, taking the public site and API gateway offline.

## Timeline
- **00:00** — Certificate reaches expiry; browsers begin rejecting the connection.
- **00:04** — Synthetic check fails; alert fires.
- **00:22** — On-call finds the ACME renewal cron had been failing due to a DNS-01 permission change.
- **00:48** — Manual certificate issued and deployed to the load balancers.
- **01:12** — All endpoints healthy; synthetic checks green.

## Root cause
An IAM policy change 27 days earlier removed the renewal role's Route53 write permission, so cert-manager could not complete the DNS-01 challenge. Renewal failures were logged but not alerted.

## Resolution
Restored the Route53 permission, re-issued the certificate, and added alerting on renewal job failures.

## Impact
Full public site and API unavailable for 68 minutes overnight.

## Action items
- Alert on ANY certificate within 21 days of expiry.
- Alert on renewal job failure, not just expiry.
- Add an IAM change review step for renewal roles.

**Tags:** tls, certificates, availability, iam
