# INC-2026-0113 — Retry storm cascaded into an upstream provider rate-limit

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-06-15 12:25 UTC  |  **Resolved:** 2026-06-15 13:30 UTC  |  **Duration:** 1h 05m
**Services affected:** shipping-service, carrier-api-adapter
**Detection:** Spike in 429s from the carrier API; Splunk showed exponential self-inflicted retry growth.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A transient carrier-API blip triggered aggressive client retries with no backoff, self-inflicting a sustained rate-limit and delaying shipping labels.

## Timeline
- **12:20** — Carrier API returns brief 500s.
- **12:25** — Clients retry immediately without jitter; request volume 8x; carrier returns 429s.
- **12:50** — Circuit breaker enabled; exponential backoff + jitter shipped as a config flag.
- **13:30** — Retry volume normal; label generation catches up.

## Root cause
Retry logic used fixed, immediate retries with no cap or jitter, amplifying a small upstream blip.

## Resolution
Enabled a circuit breaker and exponential backoff with jitter and a max-retry cap.

## Impact
Shipping-label generation delayed up to 40 minutes for ~1 hour.

## Action items
- Standardize backoff+jitter in the shared HTTP client.
- Add circuit breakers to all third-party integrations.
- Alert on self-inflicted 429 ratios.

**Tags:** resilience, retries, third-party
