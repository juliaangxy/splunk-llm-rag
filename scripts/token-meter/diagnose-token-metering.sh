#!/usr/bin/env bash
# Read-only diagnostic for the token-metering chain (plus one probe event per HEC target).
# Run on the instance where the proxy meters calls (the GPU host for AITK/DSDL usage).
#   sudo bash /opt/splunk-ai/scripts/diagnose-token-metering.sh [model]
set -uo pipefail

MODEL="${1:-foundation-sec-8b}"
OLLAMA_PROXY_PORT="${OLLAMA_PROXY_PORT:-8101}"
ROUTES="/opt/splunk-ai/token-meter-routes.json"
ENVF="/opt/splunk-ai/token-meter.env"

hr(){ printf '\n===== %s =====\n' "$1"; }

hr "this host"
hostname -I 2>/dev/null | awk '{print "private_ip(s):",$0}'

hr "proxy units"
systemctl list-units 'token-meter*' --all --no-legend 2>/dev/null || true

hr "effective proxy env (what the running proxy uses)"
for u in token-meter-ollama token-meter-vllm; do
  echo "--- ${u} ---"
  systemctl show "${u}" -p ExecStart 2>/dev/null \
    | tr ' ' '\n' | grep -E 'UPSTREAM_URL|HEC_URL|HEC_TOKEN|HEC_ROUTES_FILE|HEC_INDEX|LISTEN_PORT|BACKEND_LABEL' \
    | sed -E 's/(HEC_TOKEN=).{6}.*/\1<redacted-6+>/'
done

hr "HEC destination file (${ROUTES})"
if [[ -f "${ROUTES}" ]]; then
  sed -E 's/("hec_token": ").{6}[^"]*/\1<redacted>/' "${ROUTES}"
else
  echo "(no destination file — proxy uses HEC_URL/HEC_TOKEN from env above)"
fi

hr "local token-meter.env (${ENVF})"
[[ -f "${ENVF}" ]] && sed -E 's/(HEC_TOKEN=).{6}.*/\1<redacted-6+>/' "${ENVF}" || echo "(none)"

# Collect every distinct (hec_url, hec_token) the proxy could ship to, from the routes
# file if present, else from the proxy's env, and probe each one directly.
hr "PROBE each HEC target with the exact token the proxy would use"
python3 - "$ROUTES" "$ENVF" <<'PY'
import json, os, ssl, sys, urllib.request

routes_path, envf = sys.argv[1], sys.argv[2]
targets = []  # (url, token, index, label)

if os.path.exists(routes_path):
    try:
        cfg = json.load(open(routes_path))
        d = cfg.get("default") or {}
        if d.get("hec_url"):
            targets.append((d["hec_url"], d.get("hec_token",""), d.get("hec_index","token_metrics"), "default"))
    except Exception as e:
        print("could not parse destination file:", e)

if not targets and os.path.exists(envf):
    env = dict(l.strip().split("=",1) for l in open(envf) if "=" in l)
    targets.append((env.get("HEC_URL",""), env.get("HEC_TOKEN",""), env.get("HEC_INDEX","token_metrics"), "env"))

ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
seen=set()
for url, tok, idx, label in targets:
    key=(url,tok)
    if not url or key in seen: continue
    seen.add(key)
    body=json.dumps({"event":{"probe":"diag"},"index":idx,"sourcetype":"token_metrics"}).encode()
    req=urllib.request.Request(url, data=body, method="POST")
    req.add_header("Authorization", f"Splunk {tok}")
    req.add_header("Content-Type","application/json")
    try:
        with urllib.request.urlopen(req, timeout=8, context=ctx) as r:
            print(f"[{label}] {url}\n    -> HTTP {r.getcode()} {r.read().decode()[:120]}")
    except urllib.error.HTTPError as e:
        print(f"[{label}] {url}\n    -> HTTP {e.code} {e.read().decode()[:160]}   (4=Invalid token, 403=token/route issue)")
    except Exception as e:
        print(f"[{label}] {url}\n    -> UNREACHABLE: {e}   (network/SG/endpoint path problem)")
if not targets:
    print("no HEC targets found — proxy has no HEC configured")
PY

hr "fire a real call THROUGH the local proxy (:${OLLAMA_PROXY_PORT}) and watch for a send"
curl -s -o /dev/null -w "proxy call HTTP %{http_code}\n" --max-time 60 \
  "http://127.0.0.1:${OLLAMA_PROXY_PORT}/api/chat" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"stream\":false}" || true
sleep 3
echo "--- last proxy log lines (look for 'HEC send failed' / 'Invalid' / metric) ---"
journalctl -u token-meter-ollama --no-pager -n 15 2>/dev/null | sed 's/^/  /' || true

hr "interpretation"
cat <<'TXT'
  * PROBE returns {"code":0}         -> path+token to that HEC are GOOD.
  * PROBE returns code 4 Invalid     -> the proxy is using a token that HEC did NOT register (token mismatch).
  * PROBE UNREACHABLE/timeout        -> network/SG path to that HEC is broken.
  * proxy call HTTP 200 but no metric + no 'HEC send failed' -> usage not extracted (model/response shape).
  * 'WARN: HEC send failed'          -> see the error; usually token (4) or unreachable.
TXT
