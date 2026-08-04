# INC-2026-0119 — IAM misconfiguration allowed privilege escalation in the dev account

**Severity:** SEV1  |  **Status:** Resolved
**Opened:** 2026-08-22 10:15 UTC  |  **Resolved:** 2026-08-22 12:05 UTC  |  **Duration:** 1h 50m
**Services affected:** aws-account-dev, ci-role
**Detection:** GuardDuty 'privilege escalation' finding; corroborated by a Splunk CloudTrail correlation search.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A CI role was granted iam:PassRole with a wildcard, letting a compromised pipeline assume a higher-privilege role; caught before production impact.

## Timeline
- **09:50** — A pipeline dependency is compromised and runs in CI.
- **10:15** — GuardDuty flags an unusual AssumeRole to an admin-ish role.
- **10:40** — CI role sessions revoked; the wildcard PassRole policy removed.
- **11:30** — Blast radius scoped in CloudTrail; no production resources touched.
- **12:05** — Least-privilege policy redeployed; incident closed.

## Root cause
An overly broad iam:PassRole with Resource '*' let the CI role pass and assume privileged roles.

## Resolution
Scoped PassRole to specific role ARNs, revoked sessions, and added a permissions boundary to CI roles.

## Impact
Potential privilege escalation in a non-prod account; no confirmed misuse; no prod impact.

## Action items
- Never grant iam:PassRole with '*'.
- Apply permissions boundaries to all automation roles.
- Alert on AssumeRole to sensitive roles from CI.

**Tags:** security, iam, privilege-escalation, cloudtrail
