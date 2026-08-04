#!/usr/bin/env python3
"""Generate dummy Splunk events that mirror the 20 synthetic incident case notes.

Two modes:
  backfill  — emit historical events spread across the last N minutes (<= 24h), including a
              correlated "burst" per incident, so searches over that window show the incidents.
  live      — loop forever, emitting fresh events every INTERVAL seconds (baseline noise plus a
              rotating new incident burst) so the indexes keep receiving newer data.

Events are shipped to Splunk HEC. Each incident's events carry `incident_id` (INC-2026-01xx)
matching the case notes in S3/the Bedrock KB, so an analyst can pivot from a log to its postmortem.

Stdlib only (urllib/ssl/json) so the Docker image needs no pip install.
"""
import argparse
import json
import os
import random
import ssl
import sys
import time
import urllib.request

# --- Baseline services per index (steady, mostly-INFO noise) ---------------------------------
BASELINE = [
    ("app", "payments-api", "payments-api-1", ["POST /charge 200", "GET /health 200", "charge captured"]),
    ("app", "checkout-web", "checkout-web-2", ["GET /cart 200", "GET /checkout 200", "session started"]),
    ("app", "catalog-service", "catalog-svc-1", ["GET /items 200", "cache hit", "GET /items/{id} 200"]),
    ("infra", "kubernetes", "k8s-node-3", ["pod scheduled", "readiness probe ok", "image pulled"]),
    ("infra", "database", "pg-primary-1", ["checkpoint complete", "connection accepted", "vacuum ok"]),
    ("infra", "gpu", "gpu-node-1", ["nvidia-smi ok", "inference 200 (42ms)", "kv-cache warm"]),
    ("security", "auth", "auth-svc-1", ["login success", "token issued", "mfa verified"]),
    ("security", "cloudtrail", "aws-controlplane", ["GetObject ok", "AssumeRole ok", "DescribeInstances ok"]),
]

# --- One correlated burst per incident (matches the case notes) ------------------------------
# (incident_id, index, sourcetype, host, level, [messages])
SCENARIOS = [
    ("INC-2026-0101", "app", "payments-api", "payments-api-1", "ERROR",
     ["500 pool timeout: waited 30s for a DB connection", "pgbouncer pool 200/200 exhausted",
      "checkout charge failed: no connection available", "5xx rate 18% over 1m"]),
    ("INC-2026-0102", "app", "www-frontend", "edge-lb-1", "ERROR",
     ["TLS handshake failed: certificate expired", "SSL_ERROR_EXPIRED_CERT on *.example.com",
      "synthetic monitor: HTTPS probe failed"]),
    ("INC-2026-0103", "security", "waf", "api-gateway-1", "WARN",
     ["request rate 120000 rps on /auth/login", "rate-based rule triggered: HTTP flood",
      "blocking ASN range; challenge issued", "p95 latency 8000ms"]),
    ("INC-2026-0104", "infra", "kubernetes", "k8s-node-3", "ERROR",
     ["OOMKilled pod recommendation-service", "memory limit null; node memory pressure",
      "evicting neighbor pod catalog-service", "CrashLoopBackOff x5"]),
    ("INC-2026-0105", "app", "notification-service", "notify-svc-1", "WARN",
     ["heap 96% -> restarting", "dedupe cache size 4.2M entries unbounded",
      "OOM restart (uptime 41m)", "notification delayed 6m"]),
    ("INC-2026-0106", "security", "cloudtrail", "aws-controlplane", "WARN",
     ["PutBucketPolicy allowed s3:GetObject to *", "S3 Block Public Access disabled on reporting-exports",
      "Config rule s3-bucket-public-read-prohibited: NON_COMPLIANT"]),
    ("INC-2026-0107", "infra", "dns", "resolver-1", "ERROR",
     ["NXDOMAIN inventory-service.internal", "resolve failed for orders->inventory",
      "hosted-zone record deleted by cleanup job", "503 upstream unresolved"]),
    ("INC-2026-0108", "infra", "kafka", "kafka-broker-2", "WARN",
     ["consumer-group analytics lag 2100000", "warehouse insert throttled by index rebuild",
      "partition backlog growing"]),
    ("INC-2026-0109", "security", "auth", "corp-vpn-1", "WARN",
     ["impossible-travel sign-in for user jdoe", "VPN login from unexpected geo",
      "account auto-suspended; sessions revoked"]),
    ("INC-2026-0110", "app", "checkout-mobile", "mobile-edge-1", "ERROR",
     ["NullPointerException in checkout_v2 on app v5.2", "flag new_checkout_v2=100% mobile",
      "crash rate spike 7%", "rolled flag back to 0% for app<5.4"]),
    ("INC-2026-0111", "infra", "splunkd", "indexer-2", "ERROR",
     ["queue blocked: index=noisy_index volume 100%", "hot volume full on 3 indexers",
      "forwarder connection dropped", "maxTotalDataSizeMB unset on index"]),
    ("INC-2026-0112", "security", "cloudtrail", "aws-controlplane", "WARN",
     ["exposed AWS access key AKIA... detected", "RunInstances attempt in unused region",
      "access key deactivated", "GuardDuty: UnauthorizedAccess:IAMUser"]),
    ("INC-2026-0113", "app", "shipping-service", "shipping-svc-1", "WARN",
     ["carrier API 429 rate limited", "retry storm: 8x request volume no backoff",
      "circuit breaker opened", "label generation delayed 40m"]),
    ("INC-2026-0114", "app", "api-gateway", "api-gateway-1", "ERROR",
     ["502 bad gateway from user-service", "health check / returns 200 while not ready",
      "routing to unready targets", "target flapping healthy/unhealthy"]),
    ("INC-2026-0115", "infra", "redis", "redis-1", "WARN",
     ["cache miss storm: 3M keys expired together", "DB CPU 100% from stampede",
      "single-flight coalescing enabled", "TTL jitter applied"]),
    ("INC-2026-0116", "app", "tax-service", "tax-svc-1", "WARN",
     ["tax provider 401 token expired", "falling back to estimated tax",
      "orders flagged for review", "token rotated in Secrets Manager"]),
    ("INC-2026-0117", "infra", "database", "pg-replica-eu-1", "WARN",
     ["replica lag 92s (eu-west-1)", "bulk backfill 40M rows saturating WAL",
      "stale read detected read-after-write", "backfill throttled to small batches"]),
    ("INC-2026-0118", "infra", "splunk-hec", "forwarder-1", "ERROR",
     ["HEC 403 invalid token", "indexed volume dropped 60%", "events below floor: monitoring blind spot",
      "forwarder still sending rotated token"]),
    ("INC-2026-0119", "security", "cloudtrail", "aws-controlplane", "WARN",
     ["AssumeRole to admin role from ci-role", "iam:PassRole with Resource '*'",
      "GuardDuty: PrivilegeEscalation finding", "CI role sessions revoked"]),
    ("INC-2026-0120", "infra", "gpu", "gpu-node-1", "ERROR",
     ["CUDA driver version is insufficient", "vLLM failed to start after kernel upgrade",
      "nvidia DKMS driver not rebuilt", "node cordoned; traffic shifted"]),
]

random.seed(1337)


def _make_event(ts, index, sourcetype, host, level, message, incident_id=None):
    body = {"level": level, "service": sourcetype, "message": message}
    if incident_id:
        body["incident_id"] = incident_id
    return {
        "time": round(ts, 3),
        "host": host,
        "source": f"datagen:{sourcetype}",
        "sourcetype": sourcetype,
        "index": index,
        "event": body,
    }


def _baseline_batch(ts):
    """A small batch of steady INFO logs across services at time ts."""
    out = []
    for index, sourcetype, host, msgs in BASELINE:
        out.append(_make_event(ts + random.uniform(0, 5), index, sourcetype, host, "INFO",
                                random.choice(msgs)))
    return out


def _incident_burst(scn, start_ts):
    """Emit an incident's correlated events over ~3 minutes starting at start_ts."""
    incident_id, index, sourcetype, host, level, msgs = scn
    out = []
    for i, msg in enumerate(msgs):
        out.append(_make_event(start_ts + i * 40 + random.uniform(0, 10),
                               index, sourcetype, host, level, msg, incident_id))
    return out


def _post(hec_url, hec_token, events, verify_tls):
    if not events:
        return
    body = "\n".join(json.dumps(e) for e in events).encode("utf-8")
    req = urllib.request.Request(hec_url, data=body, method="POST")
    req.add_header("Authorization", f"Splunk {hec_token}")
    req.add_header("Content-Type", "application/json")
    ctx = ssl.create_default_context()
    if not verify_tls:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        r.read()


def _post_all(targets, events, verify_tls):
    """Post the same events to every (hec_url, hec_token) target (fan-out)."""
    for url, token in targets:
        _post(url, token, events, verify_tls)


def _parse_targets(args):
    """Return a list of (hec_url, hec_token). Multi-target from --hec-targets / HEC_TARGETS
    ('url|token' items separated by ';'); otherwise the single --hec-url/--hec-token."""
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


def run_backfill(args, targets):
    verify = args.no_verify_tls is False
    # end_offset_min back-dates the window: it ends N minutes ago instead of "now".
    now = time.time() - args.end_offset_min * 60
    window = args.duration_min * 60
    start = now - window
    total = 0
    # Baseline noise every ~30s across the window.
    ts = start
    while ts < now:
        _post_all(targets, _baseline_batch(ts), verify)
        total += len(BASELINE)
        ts += 30
    # Spread the 20 incident bursts evenly across the window.
    for i, scn in enumerate(SCENARIOS):
        offset = (i + 0.5) / len(SCENARIOS) * window
        _post_all(targets, _incident_burst(scn, start + offset), verify)
        total += len(SCENARIOS[i][5])
    print(f"backfill complete: ~{total} events over the last {args.duration_min} min "
          f"to {len(targets)} target(s) across indexes app/infra/security", flush=True)


def _runtime(default_interval):
    """Read the optional runtime-control file (RUNTIME_CONFIG) each loop so the container can be
    paused/resumed/retuned WITHOUT a restart. Returns (enabled, interval_sec)."""
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


def run_live(args, targets):
    verify = args.no_verify_tls is False
    print(f"live generator started (interval {args.interval_sec}s) -> {len(targets)} target(s)", flush=True)
    tick = 0
    while True:
        enabled, interval = _runtime(args.interval_sec)
        if enabled:
            now = time.time()
            _post_all(targets, _baseline_batch(now), verify)
            # Every ~5 ticks, emit a fresh "new/updated" incident burst (rotating through scenarios).
            if tick % 5 == 0:
                scn = SCENARIOS[(tick // 5) % len(SCENARIOS)]
                _post_all(targets, _incident_burst(scn, now), verify)
                print(f"emitted burst {scn[0]}", flush=True)
            tick += 1
        time.sleep(interval)


def main():
    p = argparse.ArgumentParser(description="Splunk incident data generator")
    p.add_argument("--mode", choices=["backfill", "live"], default=os.environ.get("DATAGEN_MODE", "backfill"))
    p.add_argument("--duration-min", type=int, default=int(os.environ.get("DURATION_MIN", "60")))
    p.add_argument("--end-offset-min", type=int, default=int(os.environ.get("END_OFFSET_MIN", "0")))
    p.add_argument("--interval-sec", type=int, default=int(os.environ.get("LIVE_INTERVAL_SEC", "60")))
    p.add_argument("--hec-url", default=os.environ.get("HEC_URL", ""))
    p.add_argument("--hec-token", default=os.environ.get("HEC_TOKEN", ""))
    # Fan-out: 'url|token' items separated by ';'. Overrides --hec-url/--hec-token when set.
    p.add_argument("--hec-targets", default=os.environ.get("HEC_TARGETS", ""))
    p.add_argument("--verify-tls", dest="no_verify_tls", action="store_false")
    p.set_defaults(no_verify_tls=(os.environ.get("HEC_VERIFY_TLS", "false").lower() != "true"))
    args = p.parse_args()

    targets = _parse_targets(args)
    if not targets:
        print("ERROR: no HEC targets — set --hec-url/--hec-token or --hec-targets (HEC_TARGETS)", file=sys.stderr)
        sys.exit(2)
    if args.mode == "backfill":
        if not (1 <= args.duration_min <= 1440):
            print("ERROR: --duration-min must be between 1 and 1440 (24h)", file=sys.stderr)
            sys.exit(2)
        run_backfill(args, targets)
    else:
        run_live(args, targets)


if __name__ == "__main__":
    main()
