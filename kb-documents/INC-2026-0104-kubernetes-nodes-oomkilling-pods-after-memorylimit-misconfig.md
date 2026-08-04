# INC-2026-0104 — Kubernetes nodes OOM-killing pods after memory-limit misconfig

**Severity:** SEV2  |  **Status:** Resolved
**Opened:** 2026-03-01 19:11 UTC  |  **Resolved:** 2026-03-01 20:30 UTC  |  **Duration:** 1h 19m
**Services affected:** recommendation-service, catalog-service
**Detection:** CrashLoopBackOff alerts from the cluster; Splunk k8s dashboard showed rising OOMKilled counts.

> _This is a fictional incident report generated for knowledge-base testing._

## Summary
A Helm value change removed memory limits on recommendation-service, letting it consume node memory and trigger the kernel OOM killer against neighboring pods.

## Timeline
- **19:05** — Deploy sets resources.limits.memory to null via a bad values override.
- **19:11** — OOMKilled events spike; recommendation-service pods crash-loop.
- **19:40** — Noisy-neighbor effect OOM-kills catalog-service pods on the same nodes.
- **20:05** — Previous Helm release rolled back; limits restored.
- **20:30** — All pods Running; error rates normal.

## Root cause
A templating error set memory limits to null; without a limit the pod's cache grew unbounded and the node OOM killer evicted co-located pods.

## Resolution
Rolled back the Helm release and reinstated explicit memory requests/limits.

## Impact
Recommendation and catalog features degraded for ~1h20m; no data loss.

## Action items
- Add an admission policy (OPA/Kyverno) rejecting pods without memory limits.
- Add CI validation of rendered Helm manifests.
- Alert on OOMKilled rate per namespace.

**Tags:** kubernetes, reliability, capacity
