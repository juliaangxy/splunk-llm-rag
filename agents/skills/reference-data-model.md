# Skill — Data model: the app / infra / security indexes

<!--skill
name: reference_data_model
description: Field reference and correlation keys for the app, infra, and security indexes, including the intentional cross-index entity overlaps used to link incidents.
category: reference
-->

The synthetic data ([`scripts/datagen/`](../../scripts/datagen)) tags every incident so you can
correlate its stages and pivot to the matching postmortem. Query these with [[tools_splunk_mcp]].

## Indexes and fields

- **`security`** — sourcetypes `auth`, `cloudtrail`, `firewall`, `endpoint`, `waf`.
  Key fields: `threat_id` (`THREAT-2026-00xx`), `attack_stage`, `mitre_technique`, `severity`,
  `user`, `src_ip`, `dest_ip`, `dest_port`, `geo_country`, `bytes_out`, `action`, `outcome`.
- **`app`** — sourcetypes `access`, `application`, `apm`.
  Key fields: `app_incident_id` (`APP-2026-00xx`), `phase`, `service`, `endpoint`, `status`,
  `latency_ms`, `error_rate_pct`, `trace_id`, `error`, `deploy_version`, `upstream`, `node`.
- **`infra`** — sourcetypes `kubernetes`, `host_metrics`, `database`, `network`, `gpu`.
  Key fields: `infra_incident_id` (`INFRA-2026-00xx`), `phase`, `component`, `node`, `pod`,
  `host`, `cpu_pct`, `mem_pct`, `disk_pct`, `state`, `reason`, `slow_query_s`, `active_queries`.
- Original narrative incidents carry `incident_id` (`INC-2026-01xx`) matching the KB case notes.

## Correlation keys

- **Within a chain:** group by `threat_id` / `app_incident_id` / `infra_incident_id`; order by
  `attack_stage` (security) or `phase` (`trigger → degradation → mitigation → recovery`).
- **Across indexes (intentional overlap):** some chains share an **entity** so you can join them:
  - `INFRA-2026-0001` — node `k8s-node-3` MemoryPressure → OOMKilled — is the root cause of
    `APP-2026-0004` (`recommendation-service` 503s on `k8s-node-3`).
  - `INFRA-2026-0003` — postgres CPU saturation on `pg-primary-1` — causes `APP-2026-0002`
    (`orders-api` slow via `upstream=pg-primary-1`).
  - Join `app.node` ↔ `infra.node`, or `app.upstream` ↔ `infra.host`, to link symptom to cause.

## Attack stages (security) / phases (app, infra)

- `attack_stage`: `recon` → `brute-force`/`initial-access` → `valid-accounts` →
  `privilege-escalation` → `lateral-movement` → `exfiltration` → `containment`.
- `phase`: `trigger` (what changed) → `degradation` (how it manifested) → `mitigation` → `recovery`.
