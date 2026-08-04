# INC-2026-0110 — Bad feature-flag rollout broke the mobile checkout

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-05-14 17:33 UTC  |  **Resolved:** 2026-05-14 18:02 UTC  |  **Duration:** 0h 29m
**Services affected:** checkout-mobile, feature-flag-service
**Detection:** Mobile crash-rate alert; Splunk RUM dashboard showed a spike tied to a flag change.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
Enabling a new checkout flow flag at 100% for mobile triggered a null-pointer crash on older app versions.

## Timeline
- **17:30** — Flag 'new_checkout_v2' set to 100% for all mobile clients.
- **17:33** — Crash rate on app v5.2 spikes; alert fires.
- **17:45** — Correlated to the flag; flag rolled back to 0% for app < v5.4.
- **18:02** — Crash rate normal; targeted rollout re-planned.

## Root cause
The new flow assumed a field only present in app v5.4+, crashing older clients when enabled globally.

## Resolution
Rolled the flag back and re-scoped it to app v5.4+ with a staged 1%/10%/50% ramp.

## Impact
~7% of mobile checkouts crashed for ~29 minutes.

## Action items
- Require min-app-version targeting for client flags.
- Enforce staged ramps (never 0->100).
- Add automatic flag rollback on crash-rate SLO breach.

**Tags:** release, feature-flags, mobile
