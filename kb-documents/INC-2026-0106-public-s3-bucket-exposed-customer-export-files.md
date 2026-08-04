# INC-2026-0106 — Public S3 bucket exposed customer export files

**Severity:** SEV1  |  **Status:** Resolved
**Opened:** 2026-03-27 11:50 UTC  |  **Resolved:** 2026-03-27 12:40 UTC  |  **Duration:** 0h 50m (exposure window ~9 days)
**Services affected:** reporting-exports (S3)
**Detection:** AWS Config rule 's3-bucket-public-read-prohibited' non-compliant; escalated by SecOps.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A reporting bucket holding customer CSV exports was made public by a misapplied bucket policy, exposing personal data for approximately 9 days.

## Timeline
- **Day 0** — A Terraform change set a permissive bucket policy while debugging cross-account access.
- **Day 9 11:50** — AWS Config flags the bucket public; SecOps paged.
- **Day 9 12:05** — Public access blocked at the account and bucket level.
- **Day 9 12:40** — Access logs reviewed; CloudTrail scoped for external GETs.

## Root cause
A temporary debug bucket policy granting s3:GetObject to '*' was committed and applied, and S3 Block Public Access was disabled on that bucket.

## Resolution
Re-enabled Block Public Access, removed the policy, rotated any referenced pre-signed URLs, and began a data-exposure assessment from access logs.

## Impact
Potential exposure of customer export files (names, emails, order history) for ~9 days; forensic review ongoing.

## Action items
- Enforce account-wide S3 Block Public Access (SCP).
- Require peer review + policy tests for any bucket-policy change.
- Enable S3 access logging + Athena review by default.

**Tags:** security, data-exposure, s3, compliance
