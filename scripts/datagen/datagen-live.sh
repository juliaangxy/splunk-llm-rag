#!/usr/bin/env bash
set -euo pipefail

# Long-running live data-generator container. Runs on a Splunk node and, by default, sends fresh
# demo data to ITSELF (localhost HEC). It can also fan out the SAME data to a LIST of Splunk hosts
# (--target, repeatable). It can be paused/resumed/retuned/stopped without a restart.
#
# This is MANUAL-ONLY — it is deliberately NOT a bootstrap stage, so continuous data never starts
# on its own and can't grow unbounded. Run it with --start when you want live data. The one-shot
# historical backfill is a separate tool: populate-splunk-data.sh.
#
# Usage:
#   sudo SPLUNK_ADMIN_PASSWORD=... ./datagen-live.sh --start [--interval-sec 60] \
#        [--target self] [--target <host>:<hec-token>] ...   # default target: self
#   sudo ./datagen-live.sh --status | --pause | --resume | --set-interval 30 | --stop
#
# Fan-out: each --target is 'self' | '<host>' | '<host>:<hec-token>'. 'self' auto-creates the local
# indexes+HEC token; a remote host needs its own HEC token (that Splunk must already have the
# app/infra/security datagen token) via '<host>:<token>' or the shared --hec-token.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

INTERVAL="${SPLUNK_DATA_LIVE_INTERVAL_SEC:-60}"
HEC_PORT="${HEC_PORT:-8088}"
MGMT_PORT="${MGMT_PORT:-8089}"
DEFAULT_TOKEN="${HEC_TOKEN:-}"
CONTAINER="${DATAGEN_LIVE_CONTAINER:-splunk-datagen}"
RUNTIME_FILE="${DATAGEN_RUNTIME_FILE:-/opt/splunk-ai/datagen.runtime}"
ACTION="auto"          # auto = bootstrap-gated start; --start forces a start
SET_INTERVAL=""
declare -a SPECS=()

[[ $# -gt 0 ]] && DATAGEN_FORCE=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)          ACTION=start; shift;;
    --stop)           ACTION=stop; shift;;
    --status)         ACTION=status; shift;;
    --pause)          ACTION=pause; shift;;
    --resume)         ACTION=resume; shift;;
    --set-interval)   ACTION=set-interval; SET_INTERVAL="$2"; shift 2;;
    --interval-sec)   INTERVAL="$2"; shift 2;;
    --target)         SPECS+=("$2"); shift 2;;
    --hec-token)      DEFAULT_TOKEN="$2"; shift 2;;
    --hec-port)       HEC_PORT="$2"; shift 2;;
    --mgmt-port)      MGMT_PORT="$2"; shift 2;;
    -h|--help)        sed -n '4,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done
require_root

# --- Runtime-control file the container re-reads every loop (in-place '>' keeps the inode) ------
_read_runtime() {
  RT_ENABLED=true; RT_INTERVAL="${INTERVAL}"
  if [[ -f "${RUNTIME_FILE}" ]]; then
    local v
    v="$(sed -n 's/^enabled=//p' "${RUNTIME_FILE}" | tail -1)"; [[ -n "${v}" ]] && RT_ENABLED="${v}"
    v="$(sed -n 's/^interval_sec=//p' "${RUNTIME_FILE}" | tail -1)"; [[ -n "${v}" ]] && RT_INTERVAL="${v}"
  fi
}
_write_runtime() { install -d "$(dirname "${RUNTIME_FILE}")"; printf 'enabled=%s\ninterval_sec=%s\n' "$1" "$2" > "${RUNTIME_FILE}"; chmod 644 "${RUNTIME_FILE}"; }

# --- Management actions (no Splunk creds needed) ---
case "${ACTION}" in
  stop)
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
      docker rm -f "${CONTAINER}" >/dev/null && log "stopped + removed live container '${CONTAINER}'"
    else log "no live container '${CONTAINER}' present"; fi
    exit 0;;
  status)
    if command -v docker >/dev/null 2>&1; then
      docker ps -a --filter "name=${CONTAINER}" --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
      echo "--- recent logs ---"; docker logs --tail 15 "${CONTAINER}" 2>/dev/null || echo "(container not present)"
    else warn "docker not found"; fi
    exit 0;;
  pause|resume|set-interval)
    _read_runtime
    case "${ACTION}" in
      pause)        _write_runtime false "${RT_INTERVAL}"; log "paused live generation (container stays up)";;
      resume)       _write_runtime true  "${RT_INTERVAL}"; log "resumed live generation";;
      set-interval) [[ "${SET_INTERVAL}" =~ ^[0-9]+$ ]] || { error "--set-interval needs an integer (seconds)"; exit 2; }
                    _write_runtime "${RT_ENABLED}" "${SET_INTERVAL}"; log "set live interval to ${SET_INTERVAL}s";;
    esac
    log "  running '${CONTAINER}' applies this within one loop — no restart needed."
    exit 0;;
esac

# Manual-only: require an explicit --start (a bare run does nothing, so it can't auto-launch).
if [[ "${ACTION}" == "auto" ]]; then
  log "datagen-live: pass --start to launch the live generator (see --help)"; exit 0
fi

# --- Resolve targets into an 'url|token;url|token' list ---------------------------------------
[[ ${#SPECS[@]} -eq 0 ]] && SPECS=(self)
HEC_TARGETS=""
for spec in "${SPECS[@]}"; do
  case "${spec}" in
    self|localhost|127.0.0.1)
      HEC_TOKEN=""    # force ensure to create/read the LOCAL datagen indexes + token
      datagen_ensure_splunk 127.0.0.1 "${HEC_PORT}" "${MGMT_PORT}"
      HEC_TARGETS+="${HEC_URL}|${HEC_TOKEN};";;
    *)
      _host="${spec%%:*}"; _tok="${DEFAULT_TOKEN}"
      [[ "${spec}" == *:* ]] && _tok="${spec#*:}"
      [[ -n "${_tok}" ]] || { error "target '${_host}' needs a HEC token — use '<host>:<token>' or --hec-token"; exit 1; }
      HEC_TARGETS+="https://${_host}:${HEC_PORT}/services/collector/event|${_tok};";;
  esac
done
HEC_TARGETS="${HEC_TARGETS%;}"

datagen_require_docker || { error "docker is required for the live generator"; exit 1; }
datagen_build_image
_write_runtime true "${INTERVAL}"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" --restart unless-stopped --network host \
  -e DATAGEN_MODE=live -e HEC_TARGETS="${HEC_TARGETS}" -e LIVE_INTERVAL_SEC="${INTERVAL}" \
  -e RUNTIME_CONFIG=/etc/datagen.runtime -v "${RUNTIME_FILE}:/etc/datagen.runtime:ro" \
  "${DATAGEN_IMAGE}" >/dev/null

log "live generator '${CONTAINER}' running every ${INTERVAL}s -> $(( $(grep -o ';' <<<"${HEC_TARGETS};" | wc -l) )) target(s)."
log "  manage: --status | --pause | --resume | --set-interval N | --stop"
