# INC-2026-0109 — Phishing led to compromised employee VPN credentials

**Severity:** SEV1  |  **Status:** Resolved
**Opened:** 2026-05-02 09:15 UTC  |  **Resolved:** 2026-05-02 13:40 UTC  |  **Duration:** 4h 25m
**Services affected:** corp-vpn, identity-provider
**Detection:** Impossible-travel sign-in alert in the IdP; corroborated by a Splunk auth-anomaly correlation search.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
An employee entered credentials on a phishing page; the attacker used them to log into the VPN from an unusual geo before MFA blocked further access.

## Timeline
- **08:30** — Employee clicks a phishing link and submits credentials.
- **09:12** — IdP records a login from an unexpected country.
- **09:15** — Impossible-travel alert fires; account auto-suspended.
- **10:00** — Session tokens revoked; password reset; MFA re-enrolled.
- **13:40** — Endpoint scanned clean; incident closed with no lateral movement found.

## Root cause
Successful credential phishing; the VPN allowed password auth before a step-up MFA check on new geos.

## Resolution
Revoked sessions, reset credentials, and enforced phishing-resistant MFA (WebAuthn) for VPN.

## Impact
One account compromised for < 1 hour; no data access confirmed; no lateral movement.

## Action items
- Roll out WebAuthn org-wide; disable password-only VPN auth.
- Quarterly phishing simulations.
- Tune impossible-travel correlation to auto-revoke sessions.

**Tags:** security, phishing, identity, mfa
