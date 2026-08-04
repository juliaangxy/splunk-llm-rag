# INC-2026-0116 — Expired third-party API token stopped tax calculations

**Severity:** SEV3  |  **Status:** Resolved
**Opened:** 2026-07-19 09:05 UTC  |  **Resolved:** 2026-07-19 09:50 UTC  |  **Duration:** 0h 45m
**Services affected:** tax-service, checkout-web
**Detection:** Spike in tax-provider 401s; Splunk alert on tax-service error budget.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A rotating API token for the tax provider expired without renewal, causing checkout to fall back to an estimated tax and flagging orders for review.

## Timeline
- **09:00** — Tax provider token reaches expiry.
- **09:05** — 401s spike; tax-service trips its fallback to estimated tax.
- **09:30** — New token issued from the provider portal and stored in Secrets Manager.
- **09:50** — Live tax calculation restored; flagged orders reprocessed.

## Root cause
The provider token was rotated manually every 90 days and this cycle was missed; no expiry alerting existed.

## Resolution
Issued a new token, moved it to Secrets Manager with rotation, and added expiry alerting.

## Impact
~45 minutes of estimated (not exact) tax on a subset of orders; all later reconciled.

## Action items
- Automate token rotation via Secrets Manager.
- Alert 7 days before any credential/token expiry.
- Make the estimated-tax fallback emit a clear metric.

**Tags:** third-party, secrets, checkout
