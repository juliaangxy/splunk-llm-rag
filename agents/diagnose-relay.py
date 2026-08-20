#!/usr/bin/env python3
"""Diagnose the intermittent `Cloud Connect details relay returned HTTP 500` from `aiagent`, producing
the facts the backend team asks for: frequency, time/volume correlation, onboarding sanity, any
trace/request ids, and the concurrency in play.

It invokes an agent with a trivial `READY` prompt (fast — we're measuring the RELAY, not agent work)
through the Splunk MCP saved-search route: first N times **serially** (one at a time) for the base
rate, then optionally a small **concurrent burst** to see if volume raises the rate. It captures the
full 500 body (scanned for ids) and greps `mlspl.log` around the run for trace/correlation ids.

Run it ON the Splunk host (localhost MCP + read access to mlspl.log). Stdlib only.

Example (on the host):
  python3 agents/diagnose-relay.py --mcp-token "$SplunkMCPToken" --admin-password "$PW" \
      --agent rcatroubleshooting --count 12 --burst 4
"""
import argparse
import base64
import concurrent.futures as cf
import datetime
import json
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request

APP = "Splunk_ML_Toolkit"
ID_PATTERNS = [
    ("uuid", re.compile(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b')),
    ("request_id", re.compile(r'(?i)(?:x-)?(?:request|req|amzn-request|correlation|trace)[-_ ]?id["\':=\s]+([A-Za-z0-9\-]{6,})')),
]


def _ctx():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def _http(method, url, headers, data=None, timeout=300):
    req = urllib.request.Request(url, method=method, data=data.encode() if isinstance(data, str) else data)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class Client:
    def __init__(self, mgmt, mcp_url, pw, token):
        self.mgmt, self.mcp_url = mgmt.rstrip("/"), mcp_url
        self.basic = "Basic " + base64.b64encode(f"admin:{pw}".encode()).decode()
        self.mcp_headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"}

    def ss_put(self, name, spl):
        base = f"{self.mgmt}/servicesNS/admin/{APP}/saved/searches"
        h = {"Authorization": self.basic, "Content-Type": "application/x-www-form-urlencoded"}
        code, _ = _http("POST", base, h, urllib.parse.urlencode({"name": name, "search": spl}))
        if code == 409:
            _http("POST", f"{base}/{urllib.parse.quote(name)}", h, urllib.parse.urlencode({"search": spl}))

    def ss_delete(self, name):
        _http("DELETE", f"{self.mgmt}/servicesNS/admin/{APP}/saved/searches/{urllib.parse.quote(name)}",
              {"Authorization": self.basic})

    def invoke(self, agent, ss_name, timeout=300):
        spl = f'| makeresults count=1 | aiagent agent_name="{agent}" prompt="Reply with only the word READY."'
        self.ss_put(ss_name, spl)
        t0 = time.time()
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "splunk_run_saved_search", "arguments": {"saved_search_name": ss_name, "app": APP}}})
        try:
            _, raw = _http("POST", self.mcp_url, self.mcp_headers, body, timeout=timeout)
        except Exception as exc:  # noqa: BLE001
            raw = f'{{"transport_error": "{exc}"}}'
        self.ss_delete(ss_name)
        dt = round(time.time() - t0, 1)
        text = raw
        for line in raw.splitlines():
            line = line[5:].strip() if line.startswith("data:") else line.strip()
            if line.startswith("{"):
                try:
                    obj = json.loads(line)
                    for c in obj.get("result", {}).get("content", []):
                        if c.get("type") == "text":
                            text = c["text"]
                except Exception:  # noqa: BLE001
                    pass
        low = text.lower()
        if "relay returned http 500" in low or "cloud connect" in low:
            status = "RELAY_500"
        elif "ready" in low:
            status = "ok"
        else:
            status = "other"
        ids = []
        for label, rx in ID_PATTERNS:
            for m in rx.findall(text):
                ids.append(f"{label}:{m if isinstance(m, str) else m[0]}")
        return {"status": status, "dt": dt, "ts": datetime.datetime.now().strftime("%H:%M:%S"),
                "ids": sorted(set(ids)), "text": text[:300]}


def scan_mlspl(path, since_epoch):
    """Grep mlspl.log for relay/aiagent/trace lines written since the run started."""
    if not path or not os.path.isfile(path):
        return [f"(mlspl.log not found at {path})"]
    hits = []
    rx = re.compile(r'(?i)(aiagent|cloud.?connect|relay|trace|request.?id|correlation|http 500)')
    try:
        with open(path, errors="replace") as f:
            for line in f.readlines()[-4000:]:
                if rx.search(line):
                    hits.append(line.rstrip()[:400])
    except Exception as exc:  # noqa: BLE001
        return [f"(could not read {path}: {exc})"]
    return hits[-40:] or ["(no matching lines in the tail of mlspl.log)"]


def main():
    p = argparse.ArgumentParser(description="Diagnose the aiagent Cloud Connect relay 500")
    p.add_argument("--mcp-url", default=os.environ.get("MCP_URL", "https://127.0.0.1:8089/services/mcp"))
    p.add_argument("--mcp-token", default=os.environ.get("SplunkMCPToken", ""))
    p.add_argument("--mgmt-url", default=os.environ.get("SPLUNK_MGMT", "https://127.0.0.1:8089"))
    p.add_argument("--admin-password", default=os.environ.get("SPLUNK_ADMIN_PASSWORD", ""))
    p.add_argument("--agent", default="rcatroubleshooting")
    p.add_argument("--count", type=int, default=12, help="serial invocations for the base-rate test")
    p.add_argument("--burst", type=int, default=4, help="concurrent invocations for the volume test (0 to skip)")
    p.add_argument("--pause", type=int, default=3, help="seconds between serial invocations")
    p.add_argument("--mlspl-log", default="/opt/splunk/var/log/splunk/mlspl.log")
    a = p.parse_args()
    if not (a.mcp_token and a.admin_password):
        print("ERROR: --mcp-token and --admin-password required", file=sys.stderr)
        sys.exit(2)

    cli = Client(a.mgmt_url, a.mcp_url, a.admin_password, a.mcp_token)
    start = time.time()
    print(f"== relay 500 diagnosis — agent={a.agent}, serial count={a.count}, burst={a.burst} ==\n")

    # --- serial (concurrency = 1) ---
    print("Phase 1 — SERIAL (one invocation at a time):")
    serial = []
    for i in range(1, a.count + 1):
        r = cli.invoke(a.agent, f"diag_serial_{i}")
        serial.append(r)
        print(f"  #{i:02d} {r['ts']} {r['dt']:>6}s  {r['status']}" + (f"  ids={r['ids']}" if r['ids'] else ""))
        if i < a.count and a.pause:
            time.sleep(a.pause)

    # --- burst (concurrency = burst) ---
    burst = []
    if a.burst > 0:
        print(f"\nPhase 2 — BURST ({a.burst} concurrent):")
        with cf.ThreadPoolExecutor(max_workers=a.burst) as ex:
            futs = [ex.submit(cli.invoke, a.agent, f"diag_burst_{i}") for i in range(a.burst)]
            for i, fut in enumerate(cf.as_completed(futs), 1):
                r = fut.result()
                burst.append(r)
                print(f"  b{i:02d} {r['ts']} {r['dt']:>6}s  {r['status']}" + (f"  ids={r['ids']}" if r['ids'] else ""))

    def rate(rs):
        f = sum(1 for r in rs if r["status"] == "RELAY_500")
        return f, len(rs), (100 * f / len(rs) if rs else 0)

    sf, sn, sp = rate(serial)
    bf, bn, bp = rate(burst)
    fail_iters = [i + 1 for i, r in enumerate(serial) if r["status"] == "RELAY_500"]
    all_ids = sorted({x for r in serial + burst for x in r["ids"]})

    print("\n" + "=" * 70)
    print("DIAGNOSIS (for the backend team)")
    print("=" * 70)
    print(f"1. FREQUENCY (serial): {sf}/{sn} failed ({sp:.0f}%). failing iterations: {fail_iters or 'none'}")
    print(f"   pattern: {'no failures' if not fail_iters else ('looks random' if len(set(_gaps(fail_iters))) > 1 else 'roughly periodic')}")
    print(f"2. CORRELATION w/ volume: serial(1-at-a-time)={sp:.0f}%  vs  burst({a.burst})={bp:.0f}%"
          + ("  -> higher under load = volume-correlated" if bp > sp + 10 else "  -> similar = not volume-driven"))
    print(f"   time span: {serial[0]['ts'] if serial else '-'} .. {(burst or serial)[-1]['ts'] if (burst or serial) else '-'}")
    ok_any = any(r["status"] == "ok" for r in serial + burst)
    print(f"3. ONBOARDING: {'some invocations SUCCEEDED' if ok_any else 'ALL failed'} — "
          + ("relay is reachable and at least partially onboarded (a total onboarding failure would be 100% errors). "
             "Confirm with a manual agent run in the AITK UI." if ok_any
             else "no success at all — verify Cloud Connect onboarding in the UI (manual agent invoke)."))
    print(f"4. TRACE / REQUEST IDs in 500 responses: {all_ids or 'none present in the relay 500 body'}")
    print(f"5. CONCURRENCY: serial phase = 1 in flight (500s here mean it's NOT caused by parallelism); "
          f"burst phase = {a.burst} in flight.")
    print(f"\n-- mlspl.log ({a.mlspl_log}) lines mentioning relay/aiagent/trace --")
    for ln in scan_mlspl(a.mlspl_log, start):
        print(f"  {ln}")


def _gaps(xs):
    return [b - a for a, b in zip(xs, xs[1:])] or [0]


if __name__ == "__main__":
    main()
