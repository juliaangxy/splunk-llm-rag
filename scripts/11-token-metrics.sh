#!/usr/bin/env bash
set -euo pipefail

# Create the token_metrics index + an HTTP Event Collector (HEC) token on THIS Splunk
# instance, then wire the local token-meter proxy to it. Drift-proof and idempotent:
# it RESTARTS Splunk so the new index/token are actually loaded, reads the registered
# HEC token BACK from Splunk (so token-meter.env can never disagree with what HEC has),
# self-tests HEC end-to-end, and restarts the Ollama metering proxy with the real token.
# Safe to copy onto an instance and re-run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
TOKEN_METRICS_INDEX="${TOKEN_METRICS_INDEX:-token_metrics}"
HEC_PORT="${HEC_PORT:-8088}"
HEC_TOKEN_NAME="${HEC_TOKEN_NAME:-aitk-token-meter}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_PROXY_PORT="${OLLAMA_PROXY_PORT:-8101}"
APP_DIR="${SPLUNK_HOME}/etc/apps/token_metrics/local"
METER_ENV_FILE="${METER_ENV_FILE:-/opt/splunk-ai/token-meter.env}"
PROXY_APP="${PROXY_APP:-/opt/splunk-ai/scripts/token-meter/token-meter-proxy/app.py}"
DEFAULT_APP="${DEFAULT_APP:-Splunk_ML_Toolkit}"
MGMT="https://127.0.0.1:8089"

require_env SPLUNK_ADMIN_PASSWORD
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
AUTH="${SPLUNK_ADMIN_USER}:${SPLUNK_ADMIN_PASSWORD}"

# Reuse the token already in token-meter.env if present, else the secret, else generate
# a stable one — so re-runs don't churn the value.
if [[ -z "${SPLUNK_HEC_TOKEN:-}" && -f "${METER_ENV_FILE}" ]]; then
  SPLUNK_HEC_TOKEN="$(sed -n 's/^HEC_TOKEN=//p' "${METER_ENV_FILE}" | head -n1)"
fi
SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN:-$(python3 -c 'import uuid;print(uuid.uuid4())')}"

log "Configuring token_metrics index + HEC on this instance"
mkdir -p "${APP_DIR}" "${SPLUNK_HOME}/etc/apps/token_metrics/metadata" \
         "${SPLUNK_HOME}/etc/apps/token_metrics/local/data/ui/views" \
         "${SPLUNK_HOME}/etc/system/local"

# Define the index in SYSTEM scope, not an app. An app-scoped indexes.conf left the index
# in a namespace ("sourceApp=token_metrics doesn't equal callerApp=search") where its
# on-disk dir was never created and events were counted-but-unsearchable. system/local is
# global, always materialised on restart, and searchable by every role/app. Remove any
# stale app-scoped copy, then append the stanza to system/local only if not already there.
SYS_INDEXES="${SPLUNK_HOME}/etc/system/local/indexes.conf"
rm -f "${APP_DIR}/indexes.conf"
if ! grep -q "^\[${TOKEN_METRICS_INDEX}\]" "${SYS_INDEXES}" 2>/dev/null; then
  cat >> "${SYS_INDEXES}" <<EOF

[${TOKEN_METRICS_INDEX}]
homePath = \$SPLUNK_DB/${TOKEN_METRICS_INDEX}/db
coldPath = \$SPLUNK_DB/${TOKEN_METRICS_INDEX}/colddb
thawedPath = \$SPLUNK_DB/${TOKEN_METRICS_INDEX}/thaweddb
disabled = 0
EOF
  log "Added [${TOKEN_METRICS_INDEX}] to ${SYS_INDEXES}"
else
  log "[${TOKEN_METRICS_INDEX}] already present in ${SYS_INDEXES}"
fi
if id -u splunk >/dev/null 2>&1; then
  chown splunk:splunk "${SYS_INDEXES}" 2>/dev/null || true
fi

cat > "${APP_DIR}/inputs.conf" <<EOF
[http]
disabled = 0
port = ${HEC_PORT}
enableSSL = 1

[http://${HEC_TOKEN_NAME}]
disabled = 0
token = ${SPLUNK_HEC_TOKEN}
index = ${TOKEN_METRICS_INDEX}
indexes = ${TOKEN_METRICS_INDEX}
sourcetype = token_metrics
EOF

cat > "${SPLUNK_HOME}/etc/apps/token_metrics/metadata/local.meta" <<'EOF'
[]
access = read : [ * ], write : [ admin ]
export = system
EOF

cat > "${SPLUNK_HOME}/etc/apps/token_metrics/local/data/ui/views/token_usage.xml" <<EOF
<dashboard version="1.1">
  <label>AI Token Usage</label>
  <fieldset submitButton="false">
    <input type="time" token="tr" searchWhenChanged="true">
      <label>Time range</label>
      <default>
        <earliest>-24h@h</earliest>
        <latest>now</latest>
      </default>
    </input>
  </fieldset>
  <row>
    <panel><title>Total tokens</title><single><search><query>index=${TOKEN_METRICS_INDEX} model=* | stats sum(total_tokens) as total</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search></single></panel>
    <panel><title>Calls</title><single><search><query>index=${TOKEN_METRICS_INDEX} model=* | stats count</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search></single></panel>
  </row>
  <row>
    <panel><title>Tokens by model</title><chart><search><query>index=${TOKEN_METRICS_INDEX} model=* | stats sum(prompt_tokens) as prompt sum(completion_tokens) as completion by model</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search><option name="charting.chart">column</option></chart></panel>
    <panel><title>Tokens by backend</title><chart><search><query>index=${TOKEN_METRICS_INDEX} model=* | stats sum(total_tokens) as total by backend</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search><option name="charting.chart">pie</option></chart></panel>
  </row>
  <row>
    <panel><title>Tokens over time by model</title><chart><search><query>index=${TOKEN_METRICS_INDEX} model=* | timechart sum(total_tokens) by model</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search><option name="charting.chart">line</option></chart></panel>
  </row>
</dashboard>
EOF

# Make token_metrics a real, VISIBLE app so the dashboard shows in the Apps menu (without
# app.conf + nav, Splunk loads the config but never surfaces the view in the UI).
mkdir -p "${SPLUNK_HOME}/etc/apps/token_metrics/default/data/ui/nav"
cat > "${SPLUNK_HOME}/etc/apps/token_metrics/default/app.conf" <<'EOF'
[install]
state = enabled
[package]
check_for_updates = false
[ui]
is_visible = 1
label = AI Token Usage
[launcher]
author = splunk-ai-platform
description = AI model token-usage metrics and dashboard
version = 1.0.0
EOF
cat > "${SPLUNK_HOME}/etc/apps/token_metrics/default/data/ui/nav/default.xml" <<'EOF'
<nav search_view="search">
  <view name="token_usage" default="true" />
  <view name="search" />
</nav>
EOF

if id -u splunk >/dev/null 2>&1; then
  chown -R splunk:splunk "${SPLUNK_HOME}/etc/apps/token_metrics"
fi

# Clean restart helper. Runs as the SPLUNK user (a root-run restart creates root-owned
# files), with a GENEROUS timeout. The old bounded `timeout 300 splunk_run restart` (root)
# got killed before the index/HEC finished loading on a heavily-apped Splunk host, which
# left the token unloaded AND the index not loaded into the running indexer (events dropped
# as "unconfigured index"). A clean, complete restart fixes both.
splunk_clean_restart() {
  local runas=()
  if [[ "$(id -un)" == "root" ]] && id -u splunk >/dev/null 2>&1; then runas=(sudo -u splunk); fi
  timeout 900 "${runas[@]}" "${SPLUNK_HOME}/bin/splunk" restart >/dev/null 2>&1 \
    || warn "splunk restart did not finish within 15m; see ${SPLUNK_HOME}/var/log/splunk/splunkd.log"
  wait_for_port 127.0.0.1 8089 180 || warn "splunkd mgmt (8089) not up after restart"
}

# Resolve $SPLUNK_DB for the on-disk index-dir report.
SPLUNK_DB_DIR="$(sed -n 's/^SPLUNK_DB=//p' "${SPLUNK_HOME}/etc/splunk-launch.conf" 2>/dev/null | head -n1)"
SPLUNK_DB_DIR="${SPLUNK_DB_DIR:-\$SPLUNK_HOME/var/lib/splunk}"
SPLUNK_DB_DIR="${SPLUNK_DB_DIR//\$SPLUNK_HOME/${SPLUNK_HOME}}"

# Bring HEC + index fully online and VERIFY END-TO-END. A new HEC token only loads on a full
# restart, and a new index must be loaded into the running indexer (else events are accepted
# with code:0 but silently dropped as "unconfigured index"). Both need a COMPLETE restart —
# so loop: restart cleanly, enable, probe HEC, and only stop when the probe event is actually
# SEARCHABLE. This is what makes a from-scratch deploy end fully working with no manual step.
log "Restarting Splunk to load the index + HEC token"
splunk_clean_restart

READY=""
REG_TOKEN=""
RESP=""
for _attempt in 1 2 3 4; do
  # Force-enable global HEC + token + index (idempotent).
  curl -sk -u "${AUTH}" "${MGMT}/services/data/inputs/http/http" -d disabled=0 -d enableSSL=1 >/dev/null 2>&1 || true
  curl -sk -u "${AUTH}" "${MGMT}/services/data/inputs/http/${HEC_TOKEN_NAME}/enable" -X POST >/dev/null 2>&1 || true
  curl -sk -u "${AUTH}" "${MGMT}/services/data/indexes/${TOKEN_METRICS_INDEX}/enable" -X POST >/dev/null 2>&1 || true
  # Read the ACTUAL registered token back (drift-proof source of truth).
  REG_TOKEN="$(curl -sk -u "${AUTH}" "${MGMT}/services/data/inputs/http/${HEC_TOKEN_NAME}?output_mode=json" \
    | python3 -c 'import sys,json
e=(json.load(sys.stdin) or {}).get("entry") or []
print(e[0]["content"].get("token","") if e else "")' 2>/dev/null || true)"
  [[ -z "${REG_TOKEN}" ]] && REG_TOKEN="${SPLUNK_HEC_TOKEN}"
  # Probe HEC, then confirm the event actually INDEXES (searchable) — not just accepted.
  RESP="$(curl -sk "https://127.0.0.1:${HEC_PORT}/services/collector/event" \
    -H "Authorization: Splunk ${REG_TOKEN}" \
    -d "{\"event\":{\"probe\":\"stage11-selftest\"},\"index\":\"${TOKEN_METRICS_INDEX}\",\"sourcetype\":\"token_metrics\"}" 2>/dev/null || true)"
  if echo "${RESP}" | grep -q '"code":0'; then
    for _t in 1 2 3 4 5 6; do
      sleep 5
      if splunk_run search "search index=${TOKEN_METRICS_INDEX} probe=stage11-selftest earliest=-10m | head 1" 2>/dev/null | grep -q stage11-selftest; then
        READY=1; break
      fi
    done
    if [[ -n "${READY}" ]]; then
      log "SUCCESS (attempt ${_attempt}): probe event is searchable in index=${TOKEN_METRICS_INDEX} — metering works."
      break
    fi
    warn "HEC accepted the probe but it did not index (attempt ${_attempt}) — index not loaded into the running indexer; clean restart"
  else
    warn "HEC rejected the token (attempt ${_attempt}): ${RESP} — clean restart to load it"
  fi
  splunk_clean_restart
done
log "Registered HEC token: ${REG_TOKEN}"

# Write token-meter.env using the REGISTERED, VERIFIED token so the proxy can't disagree.
umask 077
cat > "${METER_ENV_FILE}" <<EOF
HEC_URL=https://127.0.0.1:${HEC_PORT}/services/collector/event
HEC_TOKEN=${REG_TOKEN}
HEC_INDEX=${TOKEN_METRICS_INDEX}
PROXY_API_KEY=${PROXY_API_KEY:-}
EOF
chmod 600 "${METER_ENV_FILE}"

# If it never became searchable after 4 clean restarts, dump the exact reason.
if [[ -z "${READY}" ]]; then
  warn "token_metrics is NOT working end-to-end after 4 restarts. Diagnosis:"
  [[ -d "${SPLUNK_DB_DIR}/${TOKEN_METRICS_INDEX}" ]] \
    && warn "  index dir present: ${SPLUNK_DB_DIR}/${TOKEN_METRICS_INDEX}" \
    || warn "  index dir MISSING: ${SPLUNK_DB_DIR}/${TOKEN_METRICS_INDEX} (check ${SPLUNK_DB_DIR} is owned/writable by the splunk user)"
  warn "  last HEC response: ${RESP}"
  grep -iE "unconfigured.*${TOKEN_METRICS_INDEX}|${TOKEN_METRICS_INDEX}.*[Dd]ropping" "${SPLUNK_HOME}/var/log/splunk/splunkd.log" 2>/dev/null | tail -3 | sed 's/^/  [splunkd] /' >&2 || true
  ALLOWED="$(curl -sk -u "${AUTH}" "${MGMT}/services/authorization/roles/${SPLUNK_ADMIN_USER}?output_mode=json" \
    | python3 -c 'import sys,json
try:
  c=json.load(sys.stdin)["entry"][0]["content"]; print(",".join(c.get("srchIndexesAllowed") or []))
except Exception: print("")' 2>/dev/null)"
  warn "  role ${SPLUNK_ADMIN_USER} srchIndexesAllowed = [${ALLOWED}] (needs '*' or ${TOKEN_METRICS_INDEX})"
fi

# 6. Restart BOTH metering proxies (vLLM :8100 + Ollama :8101) so they pick up the aligned
#    HEC token/index and the destination file. Delegate to start-token-meter-proxies.sh (the
#    single source of truth for how the proxies are launched — correct upstreams, keys,
#    HEC_ROUTES_FILE) instead of hand-rolling one backend here.
START_PROXIES="${SCRIPT_DIR}/token-meter/start-token-meter-proxies.sh"
if [[ -f "${START_PROXIES}" ]]; then
  log "Restarting token-metering proxies (vLLM + Ollama) with the aligned token"
  bash "${START_PROXIES}" || warn "Could not restart the metering proxies; run ${START_PROXIES} manually"
else
  warn "start-token-meter-proxies.sh not found next to this script; restart the proxies manually"
fi

log "Done. token_metrics index active, HEC token aligned, proxy restarted."
log "Verify: curl -s http://localhost:${OLLAMA_PROXY_PORT}/api/chat -d '{\"model\":\"foundation-sec-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false}' >/dev/null ; then search index=${TOKEN_METRICS_INDEX}"
