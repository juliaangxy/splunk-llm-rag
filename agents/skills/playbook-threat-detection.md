# Skill — Threat-detection playbook

<!--skill
name: playbook_threat_detection
description: Method, SPL cookbook, and output format for detecting and characterizing attacks in the security index and mapping them to MITRE ATT&CK.
category: playbook
-->

Find attacks in the `security` index, decide real-vs-benign, correlate the stages into one incident,
and hand the analyst an evidence-backed finding. Use [[tools_splunk_mcp]] +
[[reference_data_model]] to query, [[tools_knowledge_web]] for runbooks, and [[analysis_standards]].

## Method

1. **Sweep for signal.** Scan `security` for anomalies vs. baseline: auth failures spiking from one
   source, denied port scans, WAF blocks, cloudtrail from unusual principals/geos, large `bytes_out`,
   EDR process/persistence events.
2. **Pivot on the entity.** For a candidate, pivot on `src_ip` / `user` / host and widen the window
   to catch earlier recon and later actions.
3. **Assemble the chain.** Group by `threat_id` (by entity when absent), order by `attack_stage` to
   reconstruct the kill chain: recon → initial-access/brute-force → valid-accounts →
   privilege-escalation → lateral-movement → exfiltration → containment.
4. **Map to ATT&CK.** Collect `mitre_technique` values; name the tactic for each stage.
5. **Rule benign in or out.** Compare to baseline (routine logins, allowed 443, normal API calls).
   Note the single strongest disconfirming piece of evidence.
6. **Consult the KB.** `bedrock_kb_retrieve` the closest postmortem/runbook; summarize its response
   steps and cite it.
7. **Report** in the format below, ending with *recommended* (not executed) containment.

## SPL cookbook (security)

```spl
# 1. Brute-force sources: many auth failures from one IP, then a success
index=security sourcetype=auth action=login earliest=-24h
| stats count(eval(outcome="failure")) as fails count(eval(outcome="success")) as ok values(user) as users by src_ip
| where fails >= 5 and ok >= 1 | sort - fails

# 2. Reconstruct one attack chain end-to-end
index=security threat_id="THREAT-2026-0001" | sort _time
| table _time attack_stage sourcetype action outcome user src_ip mitre_technique severity message

# 3. Impossible travel: one user, two far-apart geos in a short window
index=security sourcetype=auth action=login outcome=success earliest=-24h
| stats dc(geo_country) as geos values(geo_country) as countries min(_time) as first max(_time) as last by user
| where geos > 1 and (last-first) < 3600

# 4. Possible exfiltration: large outbound volume
index=security action=GetObject OR action=allow earliest=-24h
| stats sum(bytes_out) as bytes_out max(bytes_out) as max_single by user src_ip | where bytes_out > 1000000000 | sort - bytes_out

# 5. ATT&CK coverage across all active threats
index=security mitre_technique=* earliest=-24h
| stats values(attack_stage) as stages values(mitre_technique) as techniques max(severity) as severity count by threat_id | sort - count
```

## Output format

```
FINDING <threat_id> — <short title>
Severity:   <low|medium|high|critical>   Confidence: <low|medium|high>
Summary:    <2-3 sentences: who did what, to what, and the current state>
Kill chain: <stage → stage → …>, MITRE: <T####, …>
Evidence:   - <SPL #> → <the key numbers/values it returned>
Entities:   users=<…> src_ip=<…> dest=<…> hosts=<…>
Benign-check: <why this is / isn't a false positive; strongest disconfirming evidence>
KB / runbook: <retrieved doc + recommended response steps>
Recommended containment (not executed): <ordered steps>
```

## Worked example

`THREAT-2026-0001`: 9 `auth` failures for `root` from `203.0.113.66` (RU) in ~60s, then one
`success`, then a `cloudtrail` `AssumeRole` to `OrganizationAdmin` → chain **brute-force (T1110) →
valid-accounts (T1078) → privilege-escalation (T1548)**, severity **critical**, confidence **high**
(success + AssumeRole from the same IP that just failed 9 times is the corroboration). Retrieve the
credential-abuse runbook; recommend disabling the account, revoking assumed-role sessions, rotating
keys, blocking the source ASN.
