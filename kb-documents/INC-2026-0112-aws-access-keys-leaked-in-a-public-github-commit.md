# INC-2026-0112 — AWS access keys leaked in a public GitHub commit

**Severity:** SEV1  |  **Status:** Resolved
**Opened:** 2026-06-04 14:00 UTC  |  **Resolved:** 2026-06-04 15:20 UTC  |  **Duration:** 1h 20m
**Services affected:** ci-pipeline, aws-account-dev
**Detection:** GitHub secret scanning + AWS 'exposed credentials' notification; confirmed via CloudTrail.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A developer committed long-lived AWS access keys to a public fork; automated scanners flagged them and minor crypto-mining API calls were observed before keys were disabled.

## Timeline
- **13:35** — Keys pushed to a public repo in a .env file.
- **14:00** — GitHub + AWS exposure alerts fire; SecOps paged.
- **14:10** — Keys deactivated; user's access reviewed in CloudTrail.
- **14:50** — A few RunInstances attempts in unused regions found and blocked by SCP.
- **15:20** — Keys deleted; user moved to short-lived SSO credentials.

## Root cause
Long-lived IAM user keys stored in a .env file were committed to a public repository.

## Resolution
Disabled and deleted the keys, migrated the user to IAM Identity Center (SSO) short-lived creds, and added region-restriction SCPs.

## Impact
Brief unauthorized API activity in unused regions; no data accessed; ~$0 cost impact after credits.

## Action items
- Ban long-lived IAM user keys; enforce SSO.
- Enable pre-commit secret scanning for all repos.
- Add GuardDuty + budget anomaly alerts.

**Tags:** security, credential-leak, iam, ci
