#!/usr/bin/env bash
set -uo pipefail

# Uninstall the token-metering stack from this host — the reverse of install-token-meter.sh.
#
# By default this is a NON-destructive teardown of the proxy layer only: it stops and removes
# the metering proxies + their self-heal timer and deletes the runtime state (token-meter.env
# + destination file). It LEAVES both the staged code (scripts + the proxy app under
# /opt/splunk-ai/scripts/token-meter/token-meter-proxy) AND your Splunk token_metrics index, data, HEC token, and
# dashboard — so a reinstall can reuse them. This is why a reinstall works right after an
# uninstall: install-token-meter.sh does NOT re-stage app.py, so the app must survive.
# Add --purge-splunk to also remove the Splunk-side objects; --remove-scripts to wipe the code.
#
# Usage:
#   sudo ./uninstall-token-meter.sh                       # stop proxies + clear runtime state
#   sudo ./uninstall-token-meter.sh --remove-scripts      # ALSO delete the staged scripts + proxy app
#   sudo SPLUNK_ADMIN_PASSWORD=... ./uninstall-token-meter.sh --purge-splunk   # ALSO drop index/HEC/app (DELETES DATA)
#
# Flags:
#   --purge-splunk     Remove the HEC token, the token_metrics index (INCLUDING indexed data),
#                      and the token_metrics dashboard app, then restart Splunk. Needs
#                      SPLUNK_ADMIN_PASSWORD in the environment.
#   --remove-scripts   Also delete the staged CODE: /opt/splunk-ai/scripts/token-meter,
#                      11-token-metrics.sh, and the proxy app /opt/splunk-ai/scripts/token-meter/token-meter-proxy.
#                      Off by default so a reinstall can reuse the staged files.
#   --dry-run          Print what would be removed without changing anything.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh may not be present after a partial copy; fall back to minimal helpers if so.
if [[ -f "${SCRIPT_DIR}/../common.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../common.sh"
else
  log(){ printf '[uninstall] %s\n' "$*"; }
  warn(){ printf '[uninstall] WARN: %s\n' "$*" >&2; }
  error(){ printf '[uninstall] ERROR: %s\n' "$*" >&2; }
  require_root(){ [[ "$(id -u)" -eq 0 ]] || { error "must run as root"; exit 1; }; }
fi

PURGE_SPLUNK=false
REMOVE_SCRIPTS=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-splunk)   PURGE_SPLUNK=true; shift;;
    --remove-scripts) REMOVE_SCRIPTS=true; shift;;
    --dry-run)        DRY_RUN=true; shift;;
    -h|--help)        sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done
# A dry run only prints; a real run touches systemd/Splunk and needs root.
$DRY_RUN || require_root

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_DB="${SPLUNK_DB:-${SPLUNK_HOME}/var/lib/splunk}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
TOKEN_METRICS_INDEX="${TOKEN_METRICS_INDEX:-token_metrics}"
HEC_TOKEN_NAME="${HEC_TOKEN_NAME:-aitk-token-meter}"
HEC_PORT="${HEC_PORT:-8088}"
MGMT="https://127.0.0.1:8089"

INSTALL_ROOT="/opt/splunk-ai"
UNITS=(token-meter-vllm token-meter-ollama)
TIMER_UNITS=(token-meter-routes-refresh.timer token-meter-routes-refresh.service)

run() { if $DRY_RUN; then echo "  would run: $*"; else "$@"; fi; }
rm_path() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  if $DRY_RUN; then echo "  would remove: $p"; else rm -rf "$p" && log "removed $p"; fi
}

# ---------------------------------------------------------------------------
# 1) Stop + remove the systemd proxy units (and the routes self-heal timer).
# ---------------------------------------------------------------------------
log "Stopping token-metering systemd units"
if command -v systemctl >/dev/null 2>&1; then
  for u in "${TIMER_UNITS[@]}" "${UNITS[@]}"; do
    run systemctl disable --now "$u" 2>/dev/null || true
    run systemctl stop "$u" 2>/dev/null || true
    run systemctl reset-failed "$u" 2>/dev/null || true
  done
  rm_path /etc/systemd/system/token-meter-routes-refresh.timer
  rm_path /etc/systemd/system/token-meter-routes-refresh.service
  run systemctl daemon-reload 2>/dev/null || true
else
  warn "systemctl not found; skipping unit removal"
fi

# ---------------------------------------------------------------------------
# 2) Remove container fallbacks, if the proxies ran as containers.
# ---------------------------------------------------------------------------
for engine in docker podman; do
  command -v "$engine" >/dev/null 2>&1 || continue
  for name in "${UNITS[@]}"; do
    if "$engine" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      log "Removing $engine container $name"
      run "$engine" rm -f "$name" >/dev/null 2>&1 || true
    fi
  done
done

# ---------------------------------------------------------------------------
# 3) Remove staged proxy files (env + destination file + the proxy app).
# ---------------------------------------------------------------------------
log "Clearing runtime state under ${INSTALL_ROOT} (env + destination file)"
rm_path "${INSTALL_ROOT}/token-meter.env"
rm_path "${INSTALL_ROOT}/token-meter-routes.json"

if $REMOVE_SCRIPTS; then
  log "Removing staged code (scripts + proxy app)"
  rm_path "${INSTALL_ROOT}/scripts/token-meter"
  rm_path "${INSTALL_ROOT}/scripts/11-token-metrics.sh"
  rm_path "${INSTALL_ROOT}/scripts/token-meter/token-meter-proxy"
  # Leave common.sh only if nothing else in scripts/ needs it; safest to keep it.
  warn "kept ${INSTALL_ROOT}/scripts/common.sh (may be shared by other scripts)"
else
  log "Kept staged code (${INSTALL_ROOT}/scripts/token-meter/token-meter-proxy + scripts) so a reinstall can reuse it"
fi

# ---------------------------------------------------------------------------
# 4) Optional: remove the Splunk-side objects (DELETES INDEXED DATA).
# ---------------------------------------------------------------------------
if $PURGE_SPLUNK; then
  log "--purge-splunk: removing HEC token, index (and its data), and dashboard app"
  if [[ -z "${SPLUNK_ADMIN_PASSWORD:-}" ]]; then
    error "--purge-splunk needs SPLUNK_ADMIN_PASSWORD in the environment"; exit 1
  fi
  AUTH="${SPLUNK_ADMIN_USER}:${SPLUNK_ADMIN_PASSWORD}"

  # 4a) Delete the HEC token via REST (best-effort; also removed with the app dir below).
  if ! $DRY_RUN; then
    curl -sk -u "${AUTH}" -X DELETE "${MGMT}/services/data/inputs/http/${HEC_TOKEN_NAME}" >/dev/null 2>&1 \
      && log "deleted HEC token ${HEC_TOKEN_NAME}" || warn "could not delete HEC token via REST (removing app dir will drop it)"
  else
    echo "  would DELETE ${MGMT}/services/data/inputs/http/${HEC_TOKEN_NAME}"
  fi

  # 4b) Remove the [token_metrics] stanza from system/local/indexes.conf.
  SYS_INDEXES="${SPLUNK_HOME}/etc/system/local/indexes.conf"
  if [[ -f "${SYS_INDEXES}" ]] && grep -q "^\[${TOKEN_METRICS_INDEX}\]" "${SYS_INDEXES}"; then
    if $DRY_RUN; then
      echo "  would remove [${TOKEN_METRICS_INDEX}] stanza from ${SYS_INDEXES}"
    else
      awk -v idx="[${TOKEN_METRICS_INDEX}]" '
        $0==idx {skip=1; next}
        skip && /^\[/ {skip=0}
        !skip {print}
      ' "${SYS_INDEXES}" > "${SYS_INDEXES}.tmp" && mv "${SYS_INDEXES}.tmp" "${SYS_INDEXES}"
      id -u splunk >/dev/null 2>&1 && chown splunk:splunk "${SYS_INDEXES}" 2>/dev/null || true
      log "removed [${TOKEN_METRICS_INDEX}] stanza from ${SYS_INDEXES}"
    fi
  else
    log "no [${TOKEN_METRICS_INDEX}] stanza in ${SYS_INDEXES}"
  fi

  # 4c) Remove the dashboard app and the index data directory.
  rm_path "${SPLUNK_HOME}/etc/apps/${TOKEN_METRICS_INDEX}"
  rm_path "${SPLUNK_DB}/${TOKEN_METRICS_INDEX}"

  # 4d) Restart Splunk so the removals take effect (as the splunk user; generous timeout).
  if $DRY_RUN; then
    echo "  would restart Splunk"
  else
    log "Restarting Splunk to apply removals (up to 15m)"
    local_runas=(); id -u splunk >/dev/null 2>&1 && local_runas=(sudo -u splunk)
    timeout 900 "${local_runas[@]}" "${SPLUNK_HOME}/bin/splunk" restart >/dev/null 2>&1 \
      || warn "splunk restart did not finish cleanly; check ${SPLUNK_HOME}/var/log/splunk/splunkd.log"
  fi
else
  log "Splunk index/HEC/dashboard left intact (use --purge-splunk to remove them)."
fi

log "Done. Token-metering proxy layer removed$( $PURGE_SPLUNK && echo ' + Splunk objects purged' )."
if ! $PURGE_SPLUNK; then
  log "To reinstall: sudo SPLUNK_ADMIN_PASSWORD=... bash ${SCRIPT_DIR}/install-token-meter.sh"
fi
