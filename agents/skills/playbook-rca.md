# Skill — RCA / troubleshooting playbook

<!--skill
name: playbook_rca
description: Method, SPL, and output format for root-cause analysis across the app and infra indexes — build the timeline, follow the dependency chain from symptom to cause, propose a fix and verification.
category: playbook
-->

Take one symptom or incident id and drive it to **root cause** across `app` and `infra`: build the
timeline, follow the dependency chain from the user-visible symptom to the underlying cause, prove it
with evidence, and propose a fix plus a way to verify. Use [[tools_splunk_mcp]] +
[[reference_data_model]], [[tools_knowledge_web]] for the matching postmortem, and
[[analysis_standards]].

## Method

1. **Frame the symptom.** From the incident id (`APP-…`/`INFRA-…`) or a complaint, quantify it:
   error rate, latency, affected endpoint/service, start time.
2. **Build the timeline.** Order the incident's events by `_time`, read `phase`
   (`trigger → degradation → mitigation → recovery`); find the onset.
3. **Find what changed at onset.** A `deploy_version` change, a kernel/driver event, a traffic shift,
   a config change — within a few minutes before onset.
4. **Follow the dependency.** Hop via `upstream` / `node` / `host` / `service` from the symptom to the
   next layer down; cross into `infra` when an app latency/error points at a host/node/db.
5. **Confirm the mechanism.** Tie the resource/behavior to the failure: pool exhaustion, OOMKilled,
   429 retry storm, missing-index seq-scan, driver mismatch. Separate **trigger** (what changed) from
   **mechanism** (how it breaks) — name both.
6. **Check the KB.** `bedrock_kb_retrieve` the matching postmortem; reuse its root cause + fix.
7. **Report** RCA + fix + verification below.

## SPL cookbook

```spl
# 1. Symptom shape: error/latency over time for one service
index=app service="checkout-web" earliest=-2h
| timechart span=1m count(eval(status>=500)) as errors p95(latency_ms) as p95_ms avg(latency_ms) as avg_ms

# 2. What changed at onset? deploy version around the first error
index=app app_incident_id="APP-2026-0001" earliest=-2h | sort _time | table _time phase endpoint status latency_ms deploy_version error message

# 3. Follow the dependency: app latency -> upstream
index=app upstream=* (status>=500 OR latency_ms>1000) earliest=-2h
| stats count avg(latency_ms) as app_ms values(app_incident_id) as incident by service upstream

# 4. Confirm the infra cause on that upstream (cross-index hop)
index=infra host="pg-primary-1" earliest=-2h | timechart span=1m max(cpu_pct) as cpu max(slow_query_s) as slow_s max(active_queries) as conns

# 5. Recovery check: did the fix hold?
index=app app_incident_id="APP-2026-0001" phase=recovery earliest=-2h | stats count avg(latency_ms) as ms max(error_rate_pct) as err by service
```

## Output format

```
RCA <incident_id> — <one-line title>
Symptom:     <what users saw + numbers: error rate, latency, endpoint, onset time>
Timeline:    <onset> trigger=<what changed> → degradation=<how it manifested> → <mitigation> → <recovery>
Trigger:     <the change: deploy vX, kernel upgrade, traffic shift, token expiry…>
Mechanism:   <how it broke: NPE / pool exhaustion / OOMKilled / 429 retry storm / seq-scan…>
Dependency:  <symptom service → upstream/node/db that is the actual cause>
Evidence:    - <SPL #> → <numbers that prove it>
Root cause:  <one sentence, cause not symptom>
Fix:         <ordered, addresses the cause>
Verify:      <query/step that confirms recovery — cite the recovery-phase evidence>
KB / runbook: <retrieved postmortem + reused action items>
```

## Worked example

`APP-2026-0002` (`orders-api` `/orders` p99 180ms→2s then `504`s, `upstream=pg-primary-1`) → hop to
`infra`: `pg-primary-1` `cpu_pct` 70→99% with `slow_query_s` rising, `reason="missing index on
orders.created_at"` (`INFRA-2026-0003`). **Trigger:** query volume on an unindexed column;
**mechanism:** sequential scans saturating CPU → connection pile-up → app timeouts. **Fix:** create
the index concurrently (as the recovery phase shows). **Verify:** query #5 shows `/orders` latency
back to ~120ms and `pg-primary-1` cpu ~46%. Cite the matching KB postmortem.
