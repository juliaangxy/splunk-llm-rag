# Skill — Cross-index triage playbook

<!--skill
name: playbook_triage
description: Method, scoring rubric, SPL, and output format for collapsing app/infra/security alerts into a ranked, de-duplicated incident queue with owners and routing.
category: playbook
-->

Turn a noisy stream of alerts across `app`, `infra`, and `security` into a **ranked, de-duplicated
incident queue**: correlate related signals into one incident, score severity/urgency, assign an
owner, and route. Use [[tools_splunk_mcp]] + [[reference_data_model]], [[tools_knowledge_web]] for
déjà-vu, and [[analysis_standards]]. You reduce noise; you do not fix or contain.

## Method

1. **Gather open signals.** Pull active incident ids and error/warn bursts across all three indexes
   for the window.
2. **Cluster into incidents.** Merge by shared `*_incident_id`/`threat_id`; shared entity
   (`host`/`node`/`service`/`user`/`src_ip`); or a time-aligned cause→effect pair (infra root cause
   slightly precedes the app symptom). Give each cluster a working title.
3. **Pick the root.** Within a cluster choose the root-cause signal; demote the rest to evidence.
4. **Score.** Severity (SEV1–SEV4) from blast radius × user impact × irreversibility; urgency from
   how fast it's worsening (rising `error_rate_pct`, climbing `mem_pct`, growing lag).
5. **Assign & route.** Owning team from domain + component; routing = page / ticket / watch.
6. **De-dup against history.** `bedrock_kb_retrieve` — if a postmortem matches, inherit its known
   severity/owner.
7. **Emit the ranked queue** in the format below.

## SPL cookbook

```spl
# 1. All active incident chains across the three indexes, most-recent first
(index=app OR index=infra OR index=security) earliest=-2h (app_incident_id=* OR infra_incident_id=* OR threat_id=* OR incident_id=*)
| eval incident=coalesce(app_incident_id, infra_incident_id, threat_id, incident_id)
| stats min(_time) as first max(_time) as last count values(sourcetype) as sourcetypes max(severity) as severity by index incident | sort - last

# 2. Correlate infra root cause -> app symptom on a shared node
index=infra (state=MemoryPressure OR reason=OOMKilled OR state=saturated) earliest=-2h
| stats values(node) as node values(infra_incident_id) as infra_id by host
| join type=left node [ search index=app status>=500 earliest=-2h | stats count as app_5xx values(app_incident_id) as app_id values(service) as services by node ]
| where isnotnull(app_5xx)

# 3. Urgency: is it getting worse?
index=app app_incident_id=* earliest=-1h | timechart span=2m max(error_rate_pct) as err_pct by app_incident_id

# 4. Blast radius: how many services/hosts is one incident touching?
(index=app OR index=infra) (app_incident_id=* OR infra_incident_id=*) earliest=-2h
| eval incident=coalesce(app_incident_id, infra_incident_id) | stats dc(service) as services dc(host) as hosts dc(node) as nodes by incident | sort - hosts
```

## Scoring rubric

| SEV | Meaning | Route |
|---|---|---|
| **SEV1** | Broad user-facing outage, or active exfil/privesc | **Page** immediately |
| **SEV2** | Degraded service or contained active threat, worsening | **Page** |
| **SEV3** | Localized/slow, mitigations holding | **Ticket** |
| **SEV4** | Cosmetic / single-entity / uncertain | **Watch** |

**Owning team** by domain+component: `security` → SecOps; `app` → the owning service team; `infra` →
Platform/SRE. A cross-index incident is owned by the **root-cause** domain, symptom team as stakeholder.

## Output format

```
INCIDENT QUEUE (window: <range>)   — <N> incidents from <M> raw alerts
1. [SEV<n>] <title>   owner=<team>   route=<page|ticket|watch>
   Root cause:  <index/incident + one line>
   Evidence:    <symptoms merged in — app_5xx=…, node=…, threat stages=…>
   Impact:      blast=<services/hosts>  users=<who/what>  trend=<worsening|stable|improving>
   Correlation: <why these alerts are ONE incident — shared entity/id/time>
   KB match:    <postmortem, if any>
Merged/suppressed: <alerts folded into the above, so on-call isn't paged twice>
```

## Worked example

`INFRA-2026-0001` (`k8s-node-3` MemoryPressure → `recommendation-service` OOMKilled) and
`APP-2026-0004` (`recommendation-service` 503s on `k8s-node-3`) share the node and are time-aligned →
**one SEV2 incident**, owner **Platform/SRE** (root cause is infra), route **page** (worsening
`mem_pct`), app team as stakeholder. Two raw alerts collapse to one — on-call is paged once.
