#!/usr/bin/env python3
"""Shared engine for the domain data generators (security / app / infra).

Each domain generator supplies:
  baseline(ts) -> [events]      steady "normal" events at time ts
  SCENARIOS    -> [Scenario]    Scenario(id, burst) where burst(start_ts) -> [events]

This engine handles HEC shipping, multi-target fan-out, backfill (a historical window with the
scenario bursts spread across it) and live (loop) modes, plus a --dry-run that prints events to
stdout so you can eyeball the data without a Splunk. Stdlib only (no pip install).

Events reuse the same shape and indexes as incident_datagen.py, so app/infra/security and the
`datagen` HEC token created by lib.sh (datagen_ensure_splunk) already cover them.
"""
import argparse
import collections
import json
import os
import random
import ssl
import sys
import time
import urllib.request

Scenario = collections.namedtuple("Scenario", ["id", "burst"])


def make_event(ts, index, sourcetype, host, fields):
    """Build one HEC event. `fields` is the structured event body (a dict of fields)."""
    return {
        "time": round(ts, 3),
        "host": host,
        "source": f"datagen:{sourcetype}",
        "sourcetype": sourcetype,
        "index": index,
        "event": dict(fields),
    }


def _post(url, token, events, verify):
    if not events:
        return
    body = "\n".join(json.dumps(e) for e in events).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Authorization", f"Splunk {token}")
    req.add_header("Content-Type", "application/json")
    ctx = ssl.create_default_context()
    if not verify:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        r.read()


def _emit(targets, events, verify, dry):
    if dry:
        for e in events:
            print(json.dumps(e))
        return
    for url, token in targets:
        _post(url, token, events, verify)


def _parse_targets(args):
    raw = (args.hec_targets or "").strip()
    if raw:
        out = []
        for item in raw.split(";"):
            url, _, token = item.strip().partition("|")
            if url and token:
                out.append((url.strip(), token.strip()))
        return out
    if args.hec_url and args.hec_token:
        return [(args.hec_url, args.hec_token)]
    return []


def _build_parser(desc):
    p = argparse.ArgumentParser(description=desc)
    p.add_argument("--mode", choices=["backfill", "live"], default=os.environ.get("DATAGEN_MODE", "backfill"))
    p.add_argument("--duration-min", type=int, default=int(os.environ.get("DURATION_MIN", "60")))
    p.add_argument("--end-offset-min", type=int, default=int(os.environ.get("END_OFFSET_MIN", "0")))
    p.add_argument("--interval-sec", type=int, default=int(os.environ.get("LIVE_INTERVAL_SEC", "60")))
    p.add_argument("--hec-url", default=os.environ.get("HEC_URL", ""))
    p.add_argument("--hec-token", default=os.environ.get("HEC_TOKEN", ""))
    p.add_argument("--hec-targets", default=os.environ.get("HEC_TARGETS", ""),
                   help="fan-out: 'url|token' items separated by ';'")
    p.add_argument("--dry-run", action="store_true",
                   help="print events as JSON to stdout instead of posting to HEC")
    p.add_argument("--verify-tls", dest="no_verify_tls", action="store_false")
    p.set_defaults(no_verify_tls=(os.environ.get("HEC_VERIFY_TLS", "false").lower() != "true"))
    return p


def _runtime(default_interval):
    """Read the optional runtime-control file (RUNTIME_CONFIG) each live loop so a container can be
    paused/resumed/retuned without a restart. Returns (enabled, interval_sec)."""
    path = os.environ.get("RUNTIME_CONFIG", "").strip()
    enabled, interval = True, default_interval
    if path and os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    key, _, val = line.strip().partition("=")
                    if key == "enabled":
                        enabled = val.lower() != "false"
                    elif key == "interval_sec":
                        try:
                            interval = max(1, int(val))
                        except ValueError:
                            pass
        except OSError:
            pass
    return enabled, interval


def _backfill(args, targets, verify, dry, baseline, scenarios):
    now = time.time() - args.end_offset_min * 60
    window = args.duration_min * 60
    start = now - window
    total = 0
    ts = start
    while ts < now:
        ev = baseline(ts)
        _emit(targets, ev, verify, dry)
        total += len(ev)
        ts += 30
    for i, scn in enumerate(scenarios):
        offset = (i + 0.5) / len(scenarios) * window
        ev = scn.burst(start + offset)
        _emit(targets, ev, verify, dry)
        total += len(ev)
    dest = "stdout" if dry else f"{len(targets)} target(s)"
    print(f"backfill complete: ~{total} events ({len(scenarios)} scenario chains + baseline) "
          f"over the last {args.duration_min} min -> {dest}", file=sys.stderr, flush=True)


def _live(args, targets, verify, dry, baseline, scenarios):
    print(f"live generator started (interval {args.interval_sec}s)", file=sys.stderr, flush=True)
    tick = 0
    while True:
        enabled, interval = _runtime(args.interval_sec)
        if enabled:
            now = time.time()
            _emit(targets, baseline(now), verify, dry)
            if tick % 5 == 0:
                scn = scenarios[(tick // 5) % len(scenarios)]
                _emit(targets, scn.burst(now), verify, dry)
                print(f"emitted {scn.id}", file=sys.stderr, flush=True)
            tick += 1
        time.sleep(interval)


def run(desc, baseline, scenarios, seed=1337):
    """Entry point for a domain generator: parse args, then backfill or loop live."""
    random.seed(seed)
    args = _build_parser(desc).parse_args()
    targets = _parse_targets(args)
    dry = args.dry_run
    if not targets and not dry:
        print("ERROR: no HEC targets — set --hec-url/--hec-token or --hec-targets, or use --dry-run",
              file=sys.stderr)
        sys.exit(2)
    verify = args.no_verify_tls is False
    if args.mode == "backfill":
        if not (1 <= args.duration_min <= 1440):
            print("ERROR: --duration-min must be between 1 and 1440 (24h)", file=sys.stderr)
            sys.exit(2)
        _backfill(args, targets, verify, dry, baseline, scenarios)
    else:
        _live(args, targets, verify, dry, baseline, scenarios)
