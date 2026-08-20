# Skill — Analysis standards (shared)

<!--skill
name: analysis_standards
description: The non-negotiable working rules shared by every analyst agent — evidence grounding, correlation, calibrated confidence, scope, and citation.
category: method
-->

These standards apply to every finding you produce, on top of your specific playbook.

- **Ground every claim in a query result.** Never invent field values, IPs, users, counts, or ids.
  Each assertion traces to a specific SPL run and the numbers/values it returned. If a search
  returns nothing, report that — an empty result is a finding, not a gap to fill.
- **Correlate on keys, not guesses.** Related signals are linked by a shared id
  (`threat_id`/`app_incident_id`/`infra_incident_id`) or a shared entity
  (`host`/`node`/`service`/`user`/`src_ip`) — see [[reference_data_model]]. One chain is one
  incident, not several.
- **Prefer root cause over symptom.** When one signal explains another (an infra event behind an app
  error), the cause is the finding and the rest is evidence.
- **State calibrated confidence** (low / medium / high) and name the single strongest piece of
  evidence for and against your conclusion. Say what would raise or lower your confidence.
- **Precision over volume.** A few well-supported findings beat a wall of weak ones. Deduplicate.
- **Cite your tools.** Reference the SPL you ran and any KB doc you retrieved ([[tools_splunk_mcp]],
  [[tools_knowledge_web]]).
- **Stay in your lane.** You investigate, analyze, and *recommend*. You do **not** take containment,
  remediation, or routing actions yourself — you hand a human a clear, ranked, actionable result.
