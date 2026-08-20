#!/usr/bin/env python3
"""Test whether Bedrock AgentCore can actually RUN the AITK agents — isolating the custom MCP tool.

Hypothesis (worth confirming): agents whose tools include the custom MCP server — configured with a
PRIVATE VPC IP such as https://10.0.255.203:8000/mcp — fail to run, because AgentCore is an
AWS-managed runtime that can't reach a private VPC address; agents with no MCP tool run fine.

For every agent in aitk_agent_collection this:
  1. reads whether it has an MCP tool attached (details.versions[0].tools.mcps) + the MCP URL,
  2. invokes it with a trivial prompt through the Splunk MCP (a temporary saved search run via
     splunk_run_saved_search — the MCP forbids `aiagent` in ad-hoc queries), and
  3. records pass/fail, then correlates has-MCP vs outcome and prints a verdict.

Fully automated: it creates and deletes its own saved searches, no user intervention. Stdlib only.

Example (on the Splunk host):
  python3 agents/test-agentcore-mcp.py --mcp-token "$SplunkMCPToken" --admin-password "$PW"
"""
import argparse
import base64
import ipaddress
import json
import os
import socket
import ssl
import sys
import time
import urllib.parse
import urllib.request

APP = "Splunk_ML_Toolkit"


def is_private_host(host):
    """True if host is an RFC-1918 / link-local / loopback literal (not routable from AgentCore)."""
    try:
        ip = ipaddress.ip_address(host)
        return ip.is_private or ip.is_loopback or ip.is_link_local
    except ValueError:
        return False  # a DNS name — can't decide from the literal alone


def probe_mcp_url(url, timeout=8):
    """In-VPC reachability control: POST an MCP `initialize` to the URL from *this* host.

    Returns (reachable, http_code_or_err, connect_seconds). A 401/406/200 means the endpoint is up
    and speaking; a timeout/refused means unreachable. This runs on the Splunk host, which sits in
    the VPC — so it establishes the control ("the server is reachable from inside the VPC")."""
    parsed = urllib.parse.urlparse(url)
    host, port = parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)
    t0 = time.time()
    try:  # cheap TCP connect first (clean signal even if TLS/HTTP rejects us)
        socket.create_connection((host, port), timeout=timeout).close()
    except OSError as exc:
        return False, f"tcp connect failed: {exc}", round(time.time() - t0, 3)
    connect_s = round(time.time() - t0, 3)
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    try:
        code, _ = _http("POST", url, {"Content-Type": "application/json",
                                      "Accept": "application/json, text/event-stream"}, body, timeout=timeout)
        return True, f"http {code}", connect_s
    except Exception as exc:  # noqa: BLE001 - TCP already proved reachability
        return True, f"tcp ok, http err: {exc}", connect_s


def _ctx():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def _http(method, url, headers, data=None, timeout=240):
    req = urllib.request.Request(url, method=method,
                                 data=data.encode() if isinstance(data, str) else data)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class Api:
    def __init__(self, mgmt, mcp_url, admin_pw, mcp_token):
        self.mgmt, self.mcp_url = mgmt.rstrip("/"), mcp_url
        self.basic = "Basic " + base64.b64encode(f"admin:{admin_pw}".encode()).decode()
        self.mcp_headers = {"Authorization": f"Bearer {mcp_token}", "Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"}

    def kv(self, coll):
        url = f"{self.mgmt}/servicesNS/nobody/{APP}/storage/collections/data/{coll}?output_mode=json"
        _, raw = _http("GET", url, {"Authorization": self.basic})
        return json.loads(raw)

    def saved_search_put(self, name, spl):
        url = f"{self.mgmt}/servicesNS/admin/{APP}/saved/searches"
        body = urllib.parse.urlencode({"name": name, "search": spl})
        code, _ = _http("POST", url, {"Authorization": self.basic,
                                      "Content-Type": "application/x-www-form-urlencoded"}, body)
        if code == 409:  # exists -> update
            url2 = f"{url}/{urllib.parse.quote(name)}"
            _http("POST", url2, {"Authorization": self.basic,
                                 "Content-Type": "application/x-www-form-urlencoded"},
                  urllib.parse.urlencode({"search": spl}))

    def saved_search_delete(self, name):
        url = f"{self.mgmt}/servicesNS/admin/{APP}/saved/searches/{urllib.parse.quote(name)}"
        _http("DELETE", url, {"Authorization": self.basic})

    def mcp_run_saved(self, name, timeout=240):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "splunk_run_saved_search", "arguments": {"saved_search_name": name, "app": APP}}})
        _, raw = _http("POST", self.mcp_url, self.mcp_headers, body, timeout=timeout)
        obj = {}
        for line in raw.splitlines():
            line = line[5:].strip() if line.startswith("data:") else line.strip()
            if line.startswith("{"):
                obj = json.loads(line)
        res = obj.get("result", {})
        for c in res.get("content", []):
            if c.get("type") == "text":
                return res.get("isError", False), c["text"]
        return res.get("isError", False), json.dumps(res)


def agent_mcps(agent):
    v = agent.get("details", {}).get("versions", [{}])[0]
    return v.get("tools", {}).get("mcps", []) or []


def main():
    p = argparse.ArgumentParser(description="Test AgentCore reachability of the custom MCP via agent invocation")
    p.add_argument("--mcp-url", default=os.environ.get("MCP_URL", "https://127.0.0.1:8089/services/mcp"))
    p.add_argument("--mcp-token", default=os.environ.get("SplunkMCPToken", ""))
    p.add_argument("--mgmt-url", default=os.environ.get("SPLUNK_MGMT", "https://127.0.0.1:8089"))
    p.add_argument("--admin-password", default=os.environ.get("SPLUNK_ADMIN_PASSWORD", ""))
    p.add_argument("--agents", default="", help="comma list (default: every agent in the collection)")
    p.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                 "reports", "agentcore-mcp-test-report.md"))
    a = p.parse_args()
    if not (a.mcp_token and a.admin_password):
        print("ERROR: --mcp-token and --admin-password are required", file=sys.stderr)
        sys.exit(2)

    api = Api(a.mgmt_url, a.mcp_url, a.admin_password, a.mcp_token)

    # MCP connections (to show which URL/IP each tool points at)
    mcp_conns = {m["name"]: (m.get("details") or {}).get("url", "") for m in api.kv("aitk_mcp_collection")}

    agents = api.kv("aitk_agent_collection")
    wanted = {n.strip() for n in a.agents.split(",") if n.strip()}
    if wanted:
        agents = [ag for ag in agents if ag["name"] in wanted]

    print(f"MCP connections: { {k: v for k, v in mcp_conns.items()} }\n")

    # --- reachability control: probe each distinct MCP URL from this (in-VPC) host ---
    print("== in-VPC reachability probe (control) ==")
    probes = {}
    for cname, curl in mcp_conns.items():
        if not curl:
            continue
        reachable, detail, secs = probe_mcp_url(curl)
        host = urllib.parse.urlparse(curl).hostname or ""
        priv = is_private_host(host)
        probes[cname] = {"url": curl, "host": host, "private_ip": priv,
                         "reachable_in_vpc": reachable, "detail": detail, "connect_s": secs}
        print(f"  {cname} {curl} -> in-VPC reachable={reachable} ({detail}, connect {secs}s); "
              f"host is {'PRIVATE (RFC-1918)' if priv else 'public/DNS'}")
    print()

    rows = []
    for ag in agents:
        name = ag["name"]
        mcps = agent_mcps(ag)
        mcp_names = [m.get("name") or m.get("connection_name") or str(m) for m in mcps] if mcps else []
        has_mcp = bool(mcp_names)
        ss = f"test_agentcore_{name}"
        spl = f'| makeresults count=1 | aiagent agent_name="{name}" prompt="Reply with only the word READY."'
        print(f"invoking {name} (mcp tools={mcp_names or 'none'}) ...", flush=True)
        api.saved_search_put(ss, spl)
        t0 = time.time()
        try:
            is_err, text = api.mcp_run_saved(ss)
        except Exception as exc:  # noqa: BLE001
            is_err, text = True, str(exc)
        api.saved_search_delete(ss)
        dt = round(time.time() - t0, 1)
        text1 = text.replace("\n", " ")[:200]
        # classify
        low = text.lower()
        if not is_err and "ready" in low:
            outcome = "PASS"
        elif "relay returned http 500" in low or "cloud connect" in low or "agentcore" in low or is_err:
            outcome = "FAIL"
        else:
            outcome = "UNKNOWN"
        print(f"  -> {outcome} ({dt}s): {text1}")
        rows.append({"agent": name, "has_mcp": has_mcp, "mcp_tools": mcp_names,
                     "mcp_urls": [mcp_conns.get(n, "") for n in mcp_names],
                     "outcome": outcome, "detail": text1, "seconds": dt})

    # ---- verdict ------------------------------------------------------------
    with_mcp = [r for r in rows if r["has_mcp"]]
    no_mcp = [r for r in rows if not r["has_mcp"]]
    mcp_all_fail = with_mcp and all(r["outcome"] == "FAIL" for r in with_mcp)
    nomcp_any_pass = any(r["outcome"] == "PASS" for r in no_mcp)
    # Is any custom MCP configured with a private (VPC-only) IP that we proved is reachable in-VPC?
    private_reachable = [p for p in probes.values() if p["private_ip"] and p["reachable_in_vpc"]]

    if mcp_all_fail and nomcp_any_pass:
        verdict = ("CONFIRMED (empirical): agents WITH the custom MCP attached all failed, while an "
                   "agent WITHOUT any MCP ran — AgentCore cannot reach the private-IP MCP endpoint.")
    elif with_mcp and no_mcp and rows and all(r["outcome"] == "FAIL" for r in rows):
        verdict = ("The aiagent/AgentCore relay itself is failing for EVERY agent (incl. one with no "
                   "MCP) — fix the relay before blaming the MCP.")
    elif not with_mcp and private_reachable and (nomcp_any_pass or not rows):
        p = private_reachable[0]
        verdict = (
            "CONFIRMED (structural): no agent currently attaches the custom MCP, so every agent runs "
            "(they use only built-in Splunk search). But the custom MCP is configured with a PRIVATE "
            f"VPC IP ({p['host']}) that is reachable from inside the VPC (this host: {p['detail']}, "
            f"{p['connect_s']}s) and, being RFC-1918, is NOT routable from Bedrock AgentCore's "
            "AWS-managed network. Attach that MCP to an agent and force a tool call and it WILL fail. "
            "Fix: point the MCP at a routable endpoint (public DNS/ALB) allow-listed to AgentCore's "
            "egress, or use a native AITK Knowledge Base tool instead of a self-hosted private MCP.")
    elif not with_mcp:
        verdict = ("No agent attaches the custom MCP, so nothing exercises it — agents pass on built-in "
                   "search alone. Attach the MCP to an agent to test the private-IP path directly.")
    else:
        verdict = "MIXED / see the table — no clean has-MCP vs no-MCP split."

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write("# AgentCore ↔ custom MCP reachability test\n\n")
        fh.write("Self-contained test of whether Bedrock AgentCore can reach the AITK agents' custom MCP.\n")
        fh.write("It (1) probes each MCP URL for in-VPC reachability, (2) invokes every agent and records\n")
        fh.write("whether it has the custom MCP attached vs pass/fail.\n\n")
        fh.write(f"**MCP connections:** `{json.dumps(mcp_conns)}`\n\n")
        fh.write("## 1. In-VPC reachability probe (control — run from the Splunk host, which is in the VPC)\n\n")
        fh.write("| MCP connection | URL | host is private (RFC-1918) | reachable from in-VPC | detail |\n")
        fh.write("|---|---|---|---|---|\n")
        for cname, p in probes.items():
            fh.write(f"| {cname} | {p['url']} | {'yes' if p['private_ip'] else 'no'} | "
                     f"{'yes' if p['reachable_in_vpc'] else 'NO'} | {p['detail']}, connect {p['connect_s']}s |\n")
        fh.write("\n> A private IP that answers from inside the VPC but is RFC-1918 is, by definition, "
                 "**not routable from AgentCore's AWS-managed network** — the SG is irrelevant once the "
                 "address itself is unroutable.\n\n")
        fh.write("## 2. Agent invocation matrix (does each agent run, and does it attach the custom MCP?)\n\n")
        fh.write("| agent | has custom MCP | MCP url(s) | outcome | detail |\n|---|---|---|---|---|\n")
        for r in rows:
            fh.write(f"| {r['agent']} | {'yes' if r['has_mcp'] else 'no'} | "
                     f"{', '.join(u for u in r['mcp_urls'] if u) or '-'} | **{r['outcome']}** | {r['detail']} |\n")
        fh.write(f"\n## Verdict\n\n{verdict}\n")
    print(f"\nVerdict: {verdict}\nWrote {a.out}")


if __name__ == "__main__":
    main()
