#!/usr/bin/env bash
set -euo pipefail

# Generate /opt/splunk-ai/token-meter-routes.json — the file that tells the token-metering
# proxy WHICH Splunk HEC (url + token) to ship its metrics to. There is a single destination
# (the "default"); it is resolved from a ROLE so IPs don't have to be hard-coded — the target
# instance is found by its SplunkAiRole tag via the AWS API (falling back to this instance's
# own private IP). This is what lets the GPU host ship its token usage to the SEARCH HEAD.
#
# Inputs (env):
#   TOKEN_METER_DEFAULT_ROLE  where metrics go: "self" (this instance) | "search-head" | "gpu-host"
#                             (default: "self")
#   TOKEN_METER_DEFAULT_HOST  optional explicit host/IP for the destination (overrides the role)
#   SPLUNK_HEC_TOKEN          HEC token (from secrets); else reuse whatever this instance registered
#   HEC_PORT                  HEC port (default 8088)
#   TOKEN_METRICS_INDEX       index name (default token_metrics)
#
# After generating, (re)start the proxies so they pick it up:
#   sudo ./configure-token-meter-routes.sh && sudo ./start-token-meter-proxies.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
source "${SCRIPT_DIR}/aws-helpers.sh"   # IMDS + SplunkAiRole->IP (AWS-only role resolution)

require_root
require_cmd aws

# aws needs a region; a bare/systemd context may not have one — take it from IMDS.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$(imds_get placement/region)}"

HEC_PORT="${HEC_PORT:-8088}"
TOKEN_METRICS_INDEX="${TOKEN_METRICS_INDEX:-token_metrics}"
METER_ENV_FILE="${METER_ENV_FILE:-/opt/splunk-ai/token-meter.env}"
ROUTES_OUT="${ROUTES_OUT:-/opt/splunk-ai/token-meter-routes.json}"
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

# Resolve a role to an IP: local IP for self/own-role, else AWS lookup by SplunkAiRole tag.
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

# Explicit host wins; otherwise resolve the role to an IP.
DEST_HOST="${DEFAULT_HOST:-$(resolve_target "${DEFAULT_ROLE}")}"

# Emit the destination file. Python does the JSON shaping.
umask 077
DEST_HOST="${DEST_HOST}" SHARED_TOKEN="${SHARED_TOKEN}" \
  HEC_PORT="${HEC_PORT}" IDX="${TOKEN_METRICS_INDEX}" \
  python3 - > "${ROUTES_OUT}" <<'PY'
import json, os
host = os.environ.get("DEST_HOST") or "127.0.0.1"
token = os.environ.get("SHARED_TOKEN") or ""
port = os.environ["HEC_PORT"]
index = os.environ["IDX"]
out = {"default": {
    "hec_url": f"https://{host}:{port}/services/collector/event",
    "hec_token": token,
    "hec_index": index,
}}
print(json.dumps(out, indent=2))
PY
chmod 600 "${ROUTES_OUT}"

log "Wrote ${ROUTES_OUT}:"
sed 's/\("hec_token": "\)[^"]*/\1<redacted>/' "${ROUTES_OUT}" | sed 's/^/  /'

# Install a self-healing timer so the destination converges even when the target instance
# isn't up yet at generation time (on a fresh deploy the GPU generates its destination before
# the search head instance exists). The timer re-resolves and restarts proxies only when the
# destination actually changes; steady state is a no-op. Config source of truth stays bootstrap.env.
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
Description=Refresh token-meter HEC destination (self-heal peer IP)
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${SCRIPT_DIR}/refresh-token-meter-routes.sh
EOF
  cat > "${tmr}" <<'EOF'
[Unit]
Description=Periodically refresh token-meter HEC destination
[Timer]
OnBootSec=90s
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now token-meter-routes-refresh.timer >/dev/null 2>&1 || true
  log "Installed token-meter-routes-refresh.timer (self-heals the destination every 5m)"
}
install_refresh_timer

log "Restart the proxies to apply:  sudo ${SCRIPT_DIR}/start-token-meter-proxies.sh"
