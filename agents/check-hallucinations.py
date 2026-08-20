#!/usr/bin/env python3
"""Audit an agent's output for hallucinated references — independently verify that every entity it
cited actually exists in Splunk. Optional and standalone (complements the in-agent `verify_grounding`
skill, which is prevention; this is proof).

It parses a scenario report (or any piped agent text), extracts the concrete references the agent
cited — incident/threat ids (incl. malformed ones like a fabricated `THR-2024-0047`), IPs, and MITRE
technique ids — and runs ONE confirming query per token through the Splunk MCP: `search index=*
"<token>" | head 1`. A token that returns 0 rows appears nowhere in the data and is flagged.

Incident/threat ids are HARD (they must exist in the indexes → missing = likely hallucination); IPs
and MITRE ids are SOFT (a real CVE/technique/external IP from the KB or web_search legitimately won't
be in Splunk). Stdlib only.

Examples:
  # against a scenario report, via the NLB MCP from a laptop:
  python3 agents/check-hallucinations.py agents/reports/scenario-report-20260820-211248.md \
      --mcp-url https://<nlb>:8089/services/mcp --mcp-token "$SplunkMCPToken"
  # pipe arbitrary agent text:
  pbpaste | python3 agents/check-hallucinations.py --mcp-token "$SplunkMCPToken"
  # fail CI if any incident id is fabricated:
  python3 agents/check-hallucinations.py report.md --mcp-token "$T" --strict
"""
import argparse
import json
import os
import re
import ssl
import sys
import urllib.request

ID_RE = re.compile(r'\b[A-Z]{2,8}-\d{4}-\d{2,}\b')          # THREAT-2026-0001, APP-2026-0004, THR-2024-0047
IP_RE = re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b')
MITRE_RE = re.compile(r'\bT\d{4}(?:\.\d{3})?\b')

# Prefixes that live in the KB / are external, NOT in the Splunk indexes — so "not in indexes" is
# expected and must NOT be counted as a hallucination: INC-* = postmortem case ids (kb-documents/),
# CVE-* = external advisories. Every other X-YYYY-NNNN id (THREAT/APP/INFRA, or a fabricated THR-…)
# is an index id and must exist in the data.
KB_EXTERNAL_PREFIXES = {"INC", "CVE"}


def _prefix(tok):
    return tok.split("-", 1)[0]


def _ctx():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


class Mcp:
    def __init__(self, url, token):
        self.url = url
        self.headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                        "Accept": "application/json, text/event-stream"}

    def rows(self, spl, earliest, latest="now", timeout=60):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "splunk_run_query",
            "arguments": {"query": spl, "earliest_time": earliest, "latest_time": latest}}})
        req = urllib.request.Request(self.url, method="POST", data=body.encode())
        for k, v in self.headers.items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as r:
            raw = r.read().decode()
        obj = {}
        for line in raw.splitlines():
            line = line[5:].strip() if line.startswith("data:") else line.strip()
            if line.startswith("{"):
                obj = json.loads(line)
        res = obj.get("result", {})
        for c in res.get("content", []):
            if c.get("type") == "text":
                try:
                    return json.loads(c["text"]).get("results", [])
                except Exception:  # noqa: BLE001
                    return []
        return []


def parse_report(text):
    """A scenario report -> {agent: answer_text}; anything else -> {'(input)': text}."""
    parts = re.split(r'^## agent:\s*', text, flags=re.M)
    if len(parts) == 1:
        return {"(input)": text}
    out = {}
    for sec in parts[1:]:
        name = sec.splitlines()[0].strip()
        m = re.search(r'\*\*Answer:\*\*\s*(.*)', sec, re.S)
        out[name] = m.group(1) if m else sec
    return out


def exists(mcp, token, earliest):
    """True = found in data, False = 0 rows, None = query error (couldn't verify)."""
    tok = token.replace('"', '')
    for _ in range(2):                      # one retry — the MCP relay is occasionally flaky
        try:
            return bool(mcp.rows(f'search index=* "{tok}" | head 1', earliest))
        except Exception:  # noqa: BLE001
            continue
    return None


def _split(tokens, cache):
    found = [t for t in tokens if cache.get(t) is True]
    missing = [t for t in tokens if cache.get(t) is False]
    errored = [t for t in tokens if cache.get(t) is None]
    return found, missing, errored


def audit(mcp, name, text, earliest, check_ips, check_mitre):
    all_ids = sorted(set(ID_RE.findall(text)))
    index_ids = [t for t in all_ids if _prefix(t) not in KB_EXTERNAL_PREFIXES]   # must be in the indexes
    external_ids = [t for t in all_ids if _prefix(t) in KB_EXTERNAL_PREFIXES]    # KB/external — informational
    ips = sorted(set(IP_RE.findall(text))) if check_ips else []
    mitre = sorted(set(MITRE_RE.findall(text))) if check_mitre else []
    cache = {}
    for tok in set(index_ids) | set(ips) | set(mitre):
        cache[tok] = exists(mcp, tok, earliest)

    _, m_ids, e_ids = _split(index_ids, cache)
    _, m_ips, _ = _split(ips, cache)
    _, m_mitre, _ = _split(mitre, cache)

    print(f"\nagent: {name}")
    line = f"  index ids (THREAT/APP/INFRA…) : {len(index_ids)-len(m_ids)-len(e_ids)}/{len(index_ids)} in data"
    if m_ids:
        line += f"   ✗ FABRICATED: {', '.join(m_ids)}"
    if e_ids:
        line += f"   (· {len(e_ids)} unverified: query error)"
    print(line)
    if external_ids:
        print(f"  KB/external refs (INC/CVE)    : {', '.join(external_ids)}  (not checked vs indexes — verify in the KB)")
    if check_ips:
        print(f"  IPs                           : {len(ips)-len(m_ips)}/{len(ips)} in data"
              + (f"   ! not in data (external?): {', '.join(m_ips)}" if m_ips else ""))
    if check_mitre:
        print(f"  MITRE techniques              : {len(mitre)-len(m_mitre)}/{len(mitre)} in data"
              + (f"   ! not in data (mapped?): {', '.join(m_mitre)}" if m_mitre else ""))
    verdict = "GROUNDED" if not m_ids else f"UNGROUNDED — {len(m_ids)} fabricated index id(s)"
    if e_ids:
        verdict += f" ({len(e_ids)} unverified — query errors)"
    print(f"  -> {verdict}")
    return len(m_ids)


def main():
    p = argparse.ArgumentParser(description="Verify an agent's cited entities exist in Splunk (hallucination audit)")
    p.add_argument("report", nargs="?", help="scenario report .md (omit to read agent text from stdin)")
    p.add_argument("--mcp-url", default=os.environ.get("MCP_URL", "https://127.0.0.1:8089/services/mcp"))
    p.add_argument("--mcp-token", default=os.environ.get("SplunkMCPToken", ""))
    p.add_argument("--earliest", default="-24h", help="time window for the confirming searches (default -24h)")
    p.add_argument("--no-ips", action="store_true", help="don't check IPs")
    p.add_argument("--no-mitre", action="store_true", help="don't check MITRE technique ids")
    p.add_argument("--strict", action="store_true", help="exit non-zero if any incident/threat id is missing")
    a = p.parse_args()
    if not a.mcp_token:
        print("ERROR: --mcp-token (SplunkMCPToken) is required", file=sys.stderr)
        sys.exit(2)

    text = open(a.report, encoding="utf-8").read() if a.report else sys.stdin.read()
    agents = parse_report(text)
    mcp = Mcp(a.mcp_url, a.mcp_token)
    print(f"== hallucination audit ({'report ' + a.report if a.report else 'stdin'}, window {a.earliest}) ==")
    total_missing = 0
    for name, answer in agents.items():
        total_missing += audit(mcp, name, answer, a.earliest, not a.no_ips, not a.no_mitre)

    print(f"\n== summary: {total_missing} fabricated incident/threat id(s) across {len(agents)} section(s) ==")
    if a.strict and total_missing:
        sys.exit(1)


if __name__ == "__main__":
    main()
