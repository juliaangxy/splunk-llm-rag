#!/usr/bin/env python3
"""End-to-end SOC/SRE scenario: generate data, then exercise each AITK agent.

Steps:
  1. CHECK the required agents exist and are Available in AITK.
  2. SIMULATE — backfill security/app/infra with correlated attack/incident chains
     (scripts/datagen/{security,app,infra}_datagen.py). Skip with --skip-datagen.
  3. RUN each agent, one of two ways (--mode):
       aiagent  (default) — invoke `| aiagent agent_name="X" prompt="<role task>"` through the
                 **Splunk MCP server** (via a temporary saved search — the MCP forbids `aiagent` in
                 ad-hoc queries). This tests the agent's ACTUAL end-to-end behavior: its LLM, its
                 Splunk-search tool, and any attached tools (the custom MCP's `bedrock_kb_retrieve`,
                 `web_search`). Captures the agent's narrative answer.
       playbook — run each agent's deterministic SPL playbook via `splunk_run_query` (no LLM). Useful
                 when the agent runtime/relay is down, or to compare the raw signal the agent sees.
  4. DOCUMENT — write a markdown report.

Runs on/near the Splunk host (MCP + HEC are on the mgmt/HEC ports). Stdlib only.

Example (on the GPU host):
  python3 agents/run_scenario.py --mcp-token "$SplunkMCPToken" --admin-password "$PW" --mode aiagent
  # -> agents/reports/scenario-report-YYYYmmdd-HHMMSS.md   (pass --out <path> for an exact filename)
"""
import argparse
import base64
import datetime
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

APP = "Splunk_ML_Toolkit"

# Each agent's expected playbook skill — validated before invoking so a mis-attached skill (e.g. the
# threat-detection agent carrying the triage playbook) is caught, not silently run.
EXPECTED_PLAYBOOK = {
    "threatdetection": "playbook_threat_detection",
    "triage": "playbook_triage",
    "rcatroubleshooting": "playbook_rca",
}

# --- aiagent mode: the real role task handed to each agent (it picks its own tools/queries) -------
# Single-line prompts (SPL string). {mins} is filled with the scenario window.
TASKS = {
    "threatdetection": (
        "You are monitoring the security index. Investigate activity in the last {mins} minutes. "
        "Identify brute-force attempts, credential attacks, and multi-stage intrusions; correlate "
        "events that share a threat_id; map each to MITRE ATT&CK; and report the top threats with "
        "threat_id, severity, source IPs, affected users, and recommended containment. If a matching "
        "postmortem or runbook exists in the knowledge base, retrieve and cite it."),
    "triage": (
        "You are the on-call triage analyst. Review active incidents across the app, infra, and "
        "security indexes in the last {mins} minutes. Rank them by severity and business impact, "
        "correlate signals that share an entity (node/host/service) or an incident id across indexes, "
        "decide which are page-worthy, and assign an owning team to each. Output a ranked incident "
        "table with a one-line justification per row."),
    "rcatroubleshooting": (
        "You are the SRE on call for a user-facing degradation. Using the app and infra indexes over "
        "the last {mins} minutes, root-cause it: build the timeline, separate the trigger (what "
        "changed) from the mechanism (how it breaks), follow the dependency chain from the app "
        "symptom down to the underlying infra cause, and propose a concrete fix plus a verification "
        "step. Retrieve and cite the matching knowledge-base postmortem if one exists."),
}

# --- playbook mode: labeled SPL run through the MCP over the scenario window ----------------------
PLAYBOOKS = {
    "threatdetection": [
        ("Brute-force sources (auth failures then success)",
         "search index=security sourcetype=auth outcome=failure | stats count as fails "
         "values(user) as users values(geo_country) as geo by src_ip | where fails>=5 | sort - fails"),
        ("Attack chains by ATT&CK technique",
         "search index=security mitre_technique=* | stats values(attack_stage) as stages "
         "values(mitre_technique) as techniques max(severity) as severity count by threat_id | sort - count"),
        ("Possible data exfiltration (large outbound)",
         "search index=security action=GetObject | stats sum(bytes_out) as bytes_out "
         "max(bytes_out) as max_single by user src_ip | where bytes_out>1000000000 | sort - bytes_out"),
    ],
    "triage": [
        ("Active incidents across app/infra/security",
         "search (index=app OR index=infra OR index=security) "
         "(app_incident_id=* OR infra_incident_id=* OR threat_id=*) "
         "| eval incident=coalesce(app_incident_id,infra_incident_id,threat_id) "
         "| stats min(_time) as first max(_time) as last count max(severity) as severity "
         "values(sourcetype) as sourcetypes by index incident | sort - last"),
        ("Cross-index correlation: infra root cause -> app symptom (shared node)",
         "search index=infra (state=MemoryPressure OR reason=OOMKilled OR state=saturated) "
         "| stats values(node) as node values(infra_incident_id) as infra_id by host "
         "| join type=left node [ search index=app status>=500 "
         "| stats count as app_5xx values(app_incident_id) as app_id values(service) as services by node ] "
         "| where isnotnull(app_5xx)"),
        ("Page-worthy security incidents (privesc / exfil / critical)",
         "search index=security (attack_stage=\"privilege-escalation\" OR attack_stage=\"exfiltration\" "
         "OR severity=\"critical\") | stats values(attack_stage) as stages max(severity) as severity "
         "values(user) as users values(src_ip) as src by threat_id"),
    ],
    "rcatroubleshooting": [
        ("App symptom -> upstream dependency",
         "search index=app upstream=* (status>=500 OR latency_ms>1000) "
         "| stats count avg(latency_ms) as app_ms values(app_incident_id) as incident by service upstream"),
        ("Infra root cause on the implicated hosts",
         "search index=infra (state=saturated OR reason=OOMKilled OR state=MemoryPressure OR reason=*) "
         "| stats values(reason) as reason max(cpu_pct) as cpu max(mem_pct) as mem max(disk_pct) as disk "
         "values(infra_incident_id) as id by host | sort - cpu"),
        ("Recovery check (did the fix hold?)",
         "search index=app phase=recovery | stats count avg(latency_ms) as ms max(error_rate_pct) as err "
         "values(app_incident_id) as incident by service"),
    ],
}


def _ctx():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def _http(method, url, headers, data=None, timeout=600):
    req = urllib.request.Request(url, method=method,
                                 data=data.encode() if isinstance(data, str) else data)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class Mcp:
    def __init__(self, url, token):
        self.url = url
        self.headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                        "Accept": "application/json, text/event-stream"}

    def _call(self, name, arguments, timeout):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": {"name": name, "arguments": arguments}})
        _, raw = _http("POST", self.url, self.headers, body, timeout=timeout)
        obj = {}
        for line in raw.splitlines():
            line = line[5:].strip() if line.startswith("data:") else line.strip()
            if line.startswith("{"):
                obj = json.loads(line)
        res = obj.get("result", {})
        if res.get("isError"):
            return {"error": res.get("content")}
        for c in res.get("content", []):
            if c.get("type") == "text":
                try:
                    return json.loads(c["text"])
                except Exception:  # noqa: BLE001
                    return {"text": c["text"]}
        return res

    def run_query(self, spl, earliest="-2h", latest="now", timeout=120):
        return self._call("splunk_run_query",
                          {"query": spl, "earliest_time": earliest, "latest_time": latest}, timeout)

    def run_saved_search(self, name, timeout=600):
        return self._call("splunk_run_saved_search", {"saved_search_name": name, "app": APP}, timeout)


class Admin:
    """Admin REST for KV reads + saved-search create/delete (aiagent must run via a saved search)."""
    def __init__(self, mgmt, password):
        self.mgmt = mgmt.rstrip("/")
        self.basic = "Basic " + base64.b64encode(f"admin:{password}".encode()).decode()

    def agent_records(self):
        """Per-agent config from KV: {name: {state, mcps:[names], tools:[...], skills:[...]}}."""
        url = f"{self.mgmt}/servicesNS/nobody/{APP}/storage/collections/data/aitk_agent_collection?output_mode=json"
        _, raw = _http("GET", url, {"Authorization": self.basic}, timeout=30)
        recs = {}
        for a in json.loads(raw):
            v = (a.get("details") or {}).get("versions", [{}])[0]
            t = v.get("tools", {}) or {}
            mcps = t.get("mcps") or []
            recs[a["name"]] = {
                "state": v.get("state"),
                "mcps": [m.get("name") for m in mcps],
                "tools": sorted({tool for m in mcps for tool in (m.get("tools") or [])}),
                "skills": v.get("skills") or t.get("skills") or [],
            }
        return recs

    def saved_search_put(self, name, spl):
        base = f"{self.mgmt}/servicesNS/admin/{APP}/saved/searches"
        h = {"Authorization": self.basic, "Content-Type": "application/x-www-form-urlencoded"}
        code, _ = _http("POST", base, h, urllib.parse.urlencode({"name": name, "search": spl}))
        if code == 409:  # exists -> update
            _http("POST", f"{base}/{urllib.parse.quote(name)}", h,
                  urllib.parse.urlencode({"search": spl}))

    def saved_search_delete(self, name):
        _http("DELETE", f"{self.mgmt}/servicesNS/admin/{APP}/saved/searches/{urllib.parse.quote(name)}",
              {"Authorization": self.basic})

    def mint_hec(self):
        h = {"Authorization": self.basic, "Content-Type": "application/x-www-form-urlencoded"}
        try:
            _http("POST", f"{self.mgmt}/services/data/inputs/http/http", h, "disabled=0&enableSSL=1", timeout=30)
            _http("POST", f"{self.mgmt}/services/data/inputs/http", h,
                  "name=scenario&index=app&indexes=app,infra,security&disabled=0", timeout=30)
            _http("POST", f"{self.mgmt}/services/data/inputs/http/scenario/enable", h, "", timeout=30)
        except Exception:  # noqa: BLE001
            pass
        _, raw = _http("GET", f"{self.mgmt}/services/data/inputs/http/scenario?output_mode=json",
                       {"Authorization": self.basic}, timeout=30)
        return json.loads(raw)["entry"][0]["content"]["token"]


def simulate(datagen_dir, hec_url, hec_token, minutes):
    env = dict(os.environ, HEC_URL=hec_url, HEC_TOKEN=hec_token, HEC_VERIFY_TLS="false")
    for gen in ("security", "app", "infra"):
        print(f"  simulating {gen} ...", flush=True)
        subprocess.run([sys.executable, os.path.join(datagen_dir, f"{gen}_datagen.py"),
                        "--mode", "backfill", "--duration-min", str(minutes)], env=env, check=True)


def _spl_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _rows(out):
    if isinstance(out, dict) and "results" in out:
        return out["results"]
    return out


def _agent_answer(out):
    """Pull the agent's narrative answer out of a saved-search aiagent result."""
    rows = _rows(out)
    if isinstance(rows, list) and rows:
        r = rows[0]
        for k in ("result_1", "result", "response", "answer", "output"):
            if r.get(k):
                return r[k], r.get("status", ""), r.get("session_id", "")
        return json.dumps(r)[:4000], r.get("status", ""), r.get("session_id", "")
    if isinstance(out, dict) and out.get("error"):
        return f"ERROR: {out['error']}", "error", ""
    if isinstance(out, dict) and out.get("text"):
        return out["text"], "", ""
    return json.dumps(out)[:4000], "", ""


def validate_agents(recs, names, strict=False):
    """Pre-flight each agent before invoking. Prints a per-agent report and returns True if OK to run.
    FATAL (blocks): agent missing, not Available, or no Splunk-search tool (would hallucinate).
    WARN (prints; FATAL only with strict): no custom_mcp, no skills, or the expected playbook missing."""
    print("== validating agent configuration ==")
    fatal = False
    for n in names:
        r = recs.get(n)
        if not r:
            print(f"  {n:20} [FAIL] MISSING — create it (agents/README.md)")
            fatal = True
            continue
        crit, warn = [], []
        if r["state"] != "Available":
            crit.append(f"state is {r['state']}, not Available")
        if not any(t.startswith("splunk_") for t in r["tools"]):
            crit.append("no Splunk-search tool — attach self_mcp, or it can't query and will hallucinate")
        if "custom_mcp" not in r["mcps"]:
            warn.append("no custom_mcp attached — bedrock_kb_retrieve / web_search unavailable")
        if not r["skills"]:
            warn.append("no skills attached")
        exp = EXPECTED_PLAYBOOK.get(n)
        if exp and exp not in r["skills"]:
            have_pb = [s for s in r["skills"] if s.startswith("playbook_")] or ["none"]
            warn.append(f"expected playbook '{exp}' not attached (has: {', '.join(have_pb)})")
        mark = "FAIL" if crit else ("WARN" if warn else "OK")
        print(f"  {n:20} [{mark}] state={r['state']} mcps={r['mcps'] or '[]'} skills={r['skills'] or '[]'}")
        for m in crit:
            print(f"      ✗ {m}")
        for m in warn:
            print(f"      ! {m}")
        if crit or (strict and warn):
            fatal = True
    return not fatal


def _is_transient(answer):
    """The Cloud Connect relay 500 is intermittent (~1 in 3 invokes) — worth retrying, not a real result."""
    a = str(answer)
    return "relay returned HTTP 500" in a or "Cloud Connect details relay" in a


def run_aiagent(mcp, admin, names, mins, timeout, retries=3, retry_wait=8, pause_between=0):
    """Invoke the agents ONE AT A TIME (sequential — never in parallel) via the MCP saved-search route,
    retrying the transient Cloud Connect relay 500 and pausing `pause_between` seconds between agents so
    the Cloud Connect relay isn't hammered. Returns [(name, task, answer, status, seconds)]."""
    out = []
    for idx, n in enumerate(names):
        if idx and pause_between:
            print(f"  … pausing {pause_between}s before the next agent", flush=True)
            time.sleep(pause_between)
        task = TASKS.get(n, "Analyze the current data relevant to your role and report your findings.").format(mins=mins)
        ss = f"scenario_{n}"
        spl = f'| makeresults count=1 | aiagent agent_name="{n}" prompt="{_spl_escape(task)}"'
        print(f"  {n}: invoking aiagent (via saved search {ss}) ...", flush=True)
        admin.saved_search_put(ss, spl)
        t0 = time.time()
        answer, status, sid = "", "", ""
        for attempt in range(1, retries + 2):          # 1 try + `retries` retries
            try:
                res = mcp.run_saved_search(ss, timeout=timeout)
            except Exception as exc:  # noqa: BLE001 - one agent failing must not abort the run
                res = {"error": str(exc)}
            answer, status, sid = _agent_answer(res)
            if not (status == "error" and _is_transient(answer) and attempt <= retries):
                break
            print(f"    transient relay 500 (attempt {attempt}/{retries}); retrying in {retry_wait}s…", flush=True)
            time.sleep(retry_wait)
        admin.saved_search_delete(ss)
        dt = round(time.time() - t0, 1)
        print(f"    -> status={status or '?'} in {dt}s, {len(str(answer))} chars"
              + (f" (session {sid})" if sid else ""))
        out.append((n, task, answer, status, dt))
    return out


def run_playbook(mcp, names, mins):
    earliest = f"-{mins}m"
    out = []
    for n in names:
        print(f"  {n}:")
        steps = []
        for label, spl in PLAYBOOKS.get(n, []):
            try:
                res = mcp.run_query(spl, earliest=earliest)
            except Exception as exc:  # noqa: BLE001
                res = {"error": str(exc)}
            rows = _rows(res)
            print(f"    - {label}: {len(rows) if isinstance(rows, list) else '?'} rows")
            steps.append((label, spl, rows))
        out.append((n, steps))
    return out


def write_report(path, mode, mins, names, mcp_url, results):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# SOC/SRE scenario report\n\n")
        fh.write(f"- Mode: **{mode}** · window: last {mins} min · agents: {', '.join(names)}\n")
        if mode == "aiagent":
            fh.write(f"- Each agent invoked via `| aiagent agent_name=\"…\"` through the Splunk MCP "
                     f"(`{mcp_url}`, saved-search route) — exercising the agent's real LLM + tools.\n\n")
            for n, task, answer, status, dt in results:
                fh.write(f"## agent: {n}\n\n")
                fh.write(f"**Task:** {task}\n\n**Status:** `{status or '?'}` · {dt}s\n\n**Answer:**\n\n")
                fh.write("```\n" + str(answer).strip()[:16000] + "\n```\n\n")
        else:
            fh.write(f"- Run through the Splunk MCP (`{mcp_url}`, `splunk_run_query`).\n\n")
            for n, steps in results:
                fh.write(f"## agent: {n}\n\n")
                for label, spl, rows in steps:
                    fh.write(f"### {label}\n\n`{spl}`\n\n```json\n")
                    fh.write(json.dumps(rows, indent=2)[:4000])
                    fh.write("\n```\n\n")


def main():
    p = argparse.ArgumentParser(description="SOC/SRE scenario: simulate + exercise AITK agents via the Splunk MCP")
    p.add_argument("--mode", choices=["aiagent", "playbook"], default="aiagent",
                   help="aiagent = invoke the real agents via the MCP (default); playbook = raw SPL")
    p.add_argument("--mcp-url", default=os.environ.get("MCP_URL", "https://127.0.0.1:8089/services/mcp"))
    p.add_argument("--mcp-token", default=os.environ.get("SplunkMCPToken", ""))
    p.add_argument("--mgmt-url", default=os.environ.get("SPLUNK_MGMT", "https://127.0.0.1:8089"))
    p.add_argument("--admin-password", default=os.environ.get("SPLUNK_ADMIN_PASSWORD", ""))
    p.add_argument("--agents", default="threatdetection,triage,rcatroubleshooting")
    p.add_argument("--duration-min", type=int, default=60)
    p.add_argument("--agent-timeout", type=int, default=600, help="per-agent HTTP timeout for aiagent mode")
    p.add_argument("--retries", type=int, default=3, help="retries on the transient Cloud Connect relay 500 (aiagent mode)")
    p.add_argument("--retry-wait", type=int, default=8, help="seconds between relay-500 retries")
    p.add_argument("--pause-between", type=int, default=0,
                   help="seconds to wait between agents (aiagent mode) — space out invocations so the "
                        "Cloud Connect relay isn't overloaded. Agents always run one at a time regardless.")
    p.add_argument("--skip-validation", action="store_true", help="skip the pre-invoke agent config check (aiagent mode)")
    p.add_argument("--strict-validation", action="store_true", help="treat validation WARNs (e.g. wrong playbook) as fatal")
    p.add_argument("--datagen-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                         "..", "scripts", "datagen"))
    p.add_argument("--hec-url", default=os.environ.get("HEC_URL", "https://127.0.0.1:8088/services/collector/event"))
    p.add_argument("--hec-token", default=os.environ.get("HEC_TOKEN", ""))
    p.add_argument("--skip-datagen", action="store_true")
    p.add_argument("--out", default="",
                   help="exact report path, written verbatim. Omit to auto-write a timestamped file "
                        "agents/reports/scenario-report-YYYYmmdd-HHMMSS.md (so repeated runs don't overwrite).")
    a = p.parse_args()

    # No --out => timestamped default so repeated runs are all kept. --out => that exact path, as-is.
    if not a.out:
        a.out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reports",
                             f"scenario-report-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}.md")

    if not a.mcp_token:
        print("ERROR: --mcp-token (SplunkMCPToken) is required", file=sys.stderr)
        sys.exit(2)
    if not a.admin_password:
        print("ERROR: --admin-password is required (check agents, mint HEC, create saved searches)", file=sys.stderr)
        sys.exit(2)
    names = [n.strip() for n in a.agents.split(",") if n.strip()]
    admin = Admin(a.mgmt_url, a.admin_password)

    print("== 1. checking agents exist ==")
    recs = admin.agent_records()
    missing = [n for n in names if n not in recs]
    for n in names:
        print(f"  {n:20} {recs[n]['state'] if n in recs else 'MISSING'}")
    if missing:
        print(f"ERROR: agents not found: {missing}. Create them in AITK first (agents/README.md).",
              file=sys.stderr)
        sys.exit(1)

    # Validate configuration before invoking (aiagent mode) — catches missing tools / wrong skills.
    if a.mode == "aiagent" and not a.skip_validation:
        if not validate_agents(recs, names, strict=a.strict_validation):
            print("ERROR: agent validation failed (see above). Fix the MCP/skill attachments in AITK, "
                  "or pass --skip-validation to run anyway.", file=sys.stderr)
            sys.exit(1)

    if not a.skip_datagen:
        print("== 2. simulating (backfill security/app/infra) ==")
        hec = a.hec_token or admin.mint_hec()
        simulate(a.datagen_dir, a.hec_url, hec, a.duration_min)
        time.sleep(5)
    else:
        print("== 2. skipped datagen ==")

    mcp = Mcp(a.mcp_url, a.mcp_token)
    if a.mode == "aiagent":
        print("== 3. invoking agents via aiagent through the Splunk MCP ==")
        results = run_aiagent(mcp, admin, names, a.duration_min, a.agent_timeout,
                              retries=a.retries, retry_wait=a.retry_wait, pause_between=a.pause_between)
    else:
        print("== 3. running agent playbooks via Splunk MCP (splunk_run_query) ==")
        results = run_playbook(mcp, names, a.duration_min)

    print("== 4. writing report ==")
    write_report(a.out, a.mode, a.duration_min, names, a.mcp_url, results)

    if a.mode == "aiagent":
        print("\n== summary ==")
        ok = 0
        for n, _task, _answer, status, dt in results:
            mark = "ok" if status and status != "error" else "FAIL"
            if mark == "ok":
                ok += 1
            print(f"  {n:20} {mark:4} ({status or '?'}, {dt}s)")
        print(f"  {ok}/{len(results)} agents returned a response")
    print(f"\nWrote report -> {a.out}")


if __name__ == "__main__":
    main()
