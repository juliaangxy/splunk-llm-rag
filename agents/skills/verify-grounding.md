# Skill — Verify grounding (anti-hallucination)

<!--skill
name: verify_grounding
description: A self-verification pass any agent runs before finalizing — every asserted fact must trace to a real tool result, with a confirming query for each key entity; unverifiable claims are dropped or flagged, and "no data" is preferred over fabrication.
category: method
-->

Attach to **any** agent. Run this as the **final step before you emit your report**. It targets the
failure mode where an LLM invents plausible-looking values — fake incident ids, IPs, counts, CVEs —
that no query actually returned. If you have no working tools, say so and stop; do not fabricate.

## The rule

**Every concrete value you state must come from a tool result you actually received this session.**
Concrete values = entity ids (`threat_id`, `app_incident_id`, `infra_incident_id`, `incident_id`),
IPs, hostnames / nodes / services, users, counts and metrics, MITRE technique ids, timestamps, and
any quoted message. A value that did not appear in a tool result may **not** be presented as fact.

## The pass (before writing the final report)

1. **List your claims.** Pull every concrete value out of your draft findings.
2. **Trace each to evidence.** Name the exact query/tool result that returned it. No source → it's
   fabricated: delete it.
3. **Confirm key entities with a query.** For each entity id / IP / host you rely on, run ONE
   confirming search that must return it — e.g.:
   - `search index=security threat_id="THREAT-2026-0001" | head 1`
   - `search index=app app_incident_id="APP-2026-0002" | stats count`
   - `search index=infra host="pg-primary-1" | head 1`
   If the confirming query returns **0 rows**, the entity does not exist — remove the claim, or mark
   it explicitly as *unverified*.
4. **Numbers are computed, never guessed.** Counts, sums, percentages, and time windows come from a
   `stats` / `timechart` result. If you didn't compute it, don't state it.
5. **Separate fact from inference.** Reasoning beyond the data ("this looks like beaconing") is an
   inference — label it as such, not as an observation.

## What to emit

End the report with a short grounding check:

```
Grounding check: <N> claims, all backed by query results.
  confirmed:   <entity ids / hosts you re-queried and got a hit>
  dropped:     <anything removed because no query returned it>   (none = good)
  inferences:  <claims labeled as reasoning, not observed fact>
Tools this run: <yes: which tools returned data> | <NO — no findings made, data was inaccessible>
```

If your tools are unavailable or every confirming query returns nothing, do **not** produce findings.
Report that you could not access the data and what needs fixing. An honest "no data" always beats a
confident fabrication.
