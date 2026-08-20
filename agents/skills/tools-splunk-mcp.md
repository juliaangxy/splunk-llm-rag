# Skill — Splunk search via the Splunk MCP (`self_mcp`)

<!--skill
name: tools_splunk_mcp
description: How to query the app/infra/security indexes through the Splunk MCP (self_mcp) — the tools, time ranges, and query idioms. Pairs with reference_data_model for the fields.
category: tools
-->

You query Splunk through the **Splunk MCP connection (`self_mcp`)**. This is your primary way to get
data — always look before you conclude. Use [[reference_data_model]] for the indexes and fields.

## Tools

- **`splunk_run_query(query, earliest_time, latest_time)`** — run ad-hoc SPL and get rows back.
  - `query` starts with `search index=<app|infra|security> …` (or `| tstats …`).
  - `earliest_time`/`latest_time` are Splunk time modifiers: `-24h`, `-2h`, `-15m`, `now`.
  - A few commands are blocked in ad-hoc queries (e.g. `aiagent`); use a saved search for those.
- **`splunk_run_saved_search(saved_search_name, app)`** — run a pre-defined saved search by name.
  Use it for expensive/standard queries someone saved, or commands not allowed ad-hoc.
- **`splunk_get_indexes()`** — list the indexes you can read, when you're unsure what exists.

## How to use it well

1. **Scope tight, then widen.** Start with a bounded window (`-2h`/`-24h`) and a specific `index=`.
   Widen only when the entity trail needs earlier/later events.
2. **Aggregate, don't dump.** Prefer `stats` / `timechart` / `top` over raw event lists — return the
   counts, values, and trends you'll actually cite, not hundreds of rows.
3. **Pivot on entities.** Once you have a candidate, re-query on its `src_ip` / `user` / `host` /
   `node` / `service` / `*_incident_id` / `threat_id` to pull the whole story.
4. **Cite what you ran.** Every claim you make must trace to a query: name the SPL and the numbers or
   values it returned. If a search returns nothing, say so — don't fill the gap with a guess.
5. **Correlate on keys, not vibes.** Group and join on the shared fields in [[reference_data_model]]
   (`threat_id`, `app_incident_id`, `infra_incident_id`, shared `node`/`host`), never on assumption.

## Query idioms you'll reuse

```spl
# aggregate an index by an entity
search index=<idx> <filters> earliest=-24h | stats count values(<field>) as <f> by <entity> | sort - count

# trend / is-it-getting-worse
search index=<idx> <filters> earliest=-1h | timechart span=2m <agg> by <series>

# reconstruct one incident end-to-end
search index=<idx> <id_field>="<ID>" | sort _time | table _time <the fields that tell the story>

# cross-index join on a shared entity
search index=infra <cause> | stats values(node) as node by host
| join type=left node [ search index=app <symptom> | stats count as hits by node ] | where isnotnull(hits)
```
