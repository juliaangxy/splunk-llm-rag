#!/usr/bin/env bash
set -euo pipefail

# Generate /opt/splunk-ai/token-meter-routes.json — the routing table the token-metering
# proxy uses to decide WHICH Splunk HEC (and token) each call's metric is shipped to,
# based on request attributes (model / backend / app / ...). This lets one proxy on the
# GPU host send, say, foundation-sec-8b usage to the search head's Splunk and vLLM usage
# somewhere else, without hard-coding IPs — target instances are resolved by their
# SplunkAiRole tag via the AWS API (falling back to this instance's own private IP).
#
# Inputs (env):
#   TOKEN_METER_ROUTES        JSON array of route specs (default: []). Each element:
#                               { "match_field": "model"|"backend"|"app"|"user"|"path",
#                                 "match_value": "<value>",
#                                 "match_mode":  "equals"|"contains"|"prefix"  (optional),
#                                 "target_role": "search-head"|"gpu-host"|"self"  (where to send),
#                                 "hec_host":    "<ip/host>"   (optional, overrides target_role),
#                                 "hec_token":   "<token>"     (optional, else shared token) }
#   TOKEN_METER_DEFAULT_ROLE  where UNMATCHED calls go (default: "self" = this instance)
#   TOKEN_METER_DEFAULT_HOST  optional explicit host for the default route (overrides role)
#   SPLUNK_HEC_TOKEN          shared HEC token (from secrets); used when a route omits hec_token
#   HEC_PORT                  HEC port (default 8088)
#   TOKEN_METRICS_INDEX       index name (default token_metrics)
#
# After generating, (re)start the proxies so they pick it up:
#   sudo ./configure-token-meter-routes.sh && sudo ./start-token-meter-proxies.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
source "${SCRIPT_DIR}/aws-helpers.sh"   # IMDS + SplunkAiRole->IP (AWS-only routing)

require_root
require_cmd aws

# aws needs a region; a bare/systemd context may not have one — take it from IMDS.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$(imds_get placement/region)}"

HEC_PORT="${HEC_PORT:-8088}"
TOKEN_METRICS_INDEX="${TOKEN_METRICS_INDEX:-token_metrics}"
METER_ENV_FILE="${METER_ENV_FILE:-/opt/splunk-ai/token-meter.env}"
ROUTES_OUT="${ROUTES_OUT:-/opt/splunk-ai/token-meter-routes.json}"
ROUTES_SPEC="${TOKEN_METER_ROUTES:-[]}"
DEFAULT_ROLE="${TOKEN_METER_DEFAULT_ROLE:-self}"
DEFAULT_HOST="${TOKEN_METER_DEFAULT_HOST:-}"

# Shared token: prefer the secret; else reuse whatever this instance already registered.
SHARED_TOKEN="${SPLUNK_HEC_TOKEN:-}"
if [[ -z "${SHARED_TOKEN}" && -f "${METER_ENV_FILE}" ]]; then
  SHARED_TOKEN="$(sed -n 's/^HEC_TOKEN=//p' "${METER_ENV_FILE}" | head -n1)"
fi

LOCAL_ROLE="$(local_splunk_ai_role)"
LOCAL_IP="$(local_private_ip)"
LOCAL_IP="${LOCAL_IP:-127.0.0.1}"
log "This instance: role='${LOCAL_ROLE:-unknown}' ip=${LOCAL_IP}"

# Validate the spec is JSON up front so we fail loudly, not silently.
if ! printf '%s' "${ROUTES_SPEC}" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
  error "TOKEN_METER_ROUTES is not valid JSON: ${ROUTES_SPEC}"
  exit 1
fi

# Resolve a target_role to an IP: local IP for self/own-role, else AWS lookup by tag.
resolve_target() {
  local role="$1" ip
  if [[ -z "${role}" || "${role}" == "self" || "${role}" == "${LOCAL_ROLE}" ]]; then
    echo "${LOCAL_IP}"; return 0
  fi
  ip="$(resolve_role_ip "${role}")"
  if [[ -z "${ip}" ]]; then
    warn "Could not resolve an IP for SplunkAiRole='${role}'; falling back to ${LOCAL_IP}"
    ip="${LOCAL_IP}"
  fi
  echo "${ip}"
}

# Collect every distinct role referenced (default + per-route) and resolve each once.
declare -A ROLE_IP
mapfile_roles() {
  printf '%s' "${ROUTES_SPEC}" | python3 -c '
import sys, json
spec = json.load(sys.stdin)
roles = {r.get("target_role") for r in spec if r.get("target_role")}
print("\n".join(sorted(x for x in roles if x)))'
}
ROLE_IP["${DEFAULT_ROLE}"]="$(resolve_target "${DEFAULT_ROLE}")"
while IFS= read -r _role; do
  [[ -z "${_role}" ]] && continue
  ROLE_IP["${_role}"]="$(resolve_target "${_role}")"
done < <(mapfile_roles)

# Serialise the resolved role→IP map as JSON for the Python emitter.
role_ip_json="{"
_first=1
for _role in "${!ROLE_IP[@]}"; do
  [[ ${_first} -eq 0 ]] && role_ip_json+=","
  role_ip_json+="\"${_role}\":\"${ROLE_IP[${_role}]}\""
  _first=0
done
role_ip_json+="}"

# Emit the final routes file. Python does the JSON shaping; bash supplied resolved IPs.
umask 077
ROUTES_SPEC="${ROUTES_SPEC}" ROLE_IP_JSON="${role_ip_json}" \
  DEFAULT_ROLE="${DEFAULT_ROLE}" DEFAULT_HOST="${DEFAULT_HOST}" LOCAL_IP="${LOCAL_IP}" \
  SHARED_TOKEN="${SHARED_TOKEN}" HEC_PORT="${HEC_PORT}" IDX="${TOKEN_METRICS_INDEX}" \
  python3 - > "${ROUTES_OUT}" <<'PY'
import json, os

spec = json.loads(os.environ["ROUTES_SPEC"])
role_ip = json.loads(os.environ["ROLE_IP_JSON"])
default_role = os.environ["DEFAULT_ROLE"]
default_host = os.environ.get("DEFAULT_HOST") or ""
local_ip = os.environ.get("LOCAL_IP") or "127.0.0.1"
shared = os.environ.get("SHARED_TOKEN") or ""
port = os.environ["HEC_PORT"]
index = os.environ["IDX"]

def host_for(role, explicit_host):
    if explicit_host:
        return explicit_host
    return role_ip.get(role) or local_ip

def url_for(host):
    return f"https://{host}:{port}/services/collector/event"

def route_obj(host, token):
    return {"hec_url": url_for(host), "hec_token": token or shared, "hec_index": index}

out = {"default": route_obj(host_for(default_role, default_host), shared), "routes": []}
for r in spec:
    host = host_for(r.get("target_role") or default_role, r.get("hec_host"))
    ro = route_obj(host, r.get("hec_token"))
    ro["match_field"] = r.get("match_field") or "model"
    ro["match_value"] = r.get("match_value") or ""
    ro["match_mode"] = r.get("match_mode") or "equals"
    out["routes"].append(ro)

print(json.dumps(out, indent=2))
PY
chmod 600 "${ROUTES_OUT}"

log "Wrote ${ROUTES_OUT}:"
sed 's/\("hec_token": "\)[^"]*/\1<redacted>/' "${ROUTES_OUT}" | sed 's/^/  /'

# Install a self-healing timer so routes converge even when a target instance isn't up
# yet at generation time (on a fresh deploy the GPU generates routes before the search
# head instance exists). The timer re-resolves and restarts proxies only when the routes
# actually change; steady state is a no-op. Config source of truth stays bootstrap.env.
install_refresh_timer() {
  [[ "${INSTALL_REFRESH_TIMER:-true}" == "true" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  local svc=/etc/systemd/system/token-meter-routes-refresh.service
  local tmr=/etc/systemd/system/token-meter-routes-refresh.timer
  if [[ -f "${tmr}" && -f "${svc}" ]]; then
    systemctl enable --now token-meter-routes-refresh.timer >/dev/null 2>&1 || true
    return 0
  fi
  cat > "${svc}" <<EOF
[Unit]
Description=Refresh token-meter HEC routing table (self-heal peer IPs)
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${SCRIPT_DIR}/refresh-token-meter-routes.sh
EOF
  cat > "${tmr}" <<'EOF'
[Unit]
Description=Periodically refresh token-meter HEC routing table
[Timer]
OnBootSec=90s
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now token-meter-routes-refresh.timer >/dev/null 2>&1 || true
  log "Installed token-meter-routes-refresh.timer (self-heals routes every 5m)"
}
install_refresh_timer

log "Restart the proxies to apply:  sudo ${SCRIPT_DIR}/start-token-meter-proxies.sh"
