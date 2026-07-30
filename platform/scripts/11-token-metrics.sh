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
PROXY_APP="${PROXY_APP:-/opt/splunk-ai/token-meter-proxy/app.py}"
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
    <panel><title>Total tokens</title><single><search><query>index=${TOKEN_METRICS_INDEX} | stats sum(total_tokens) as total</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search></single></panel>
    <panel><title>Calls</title><single><search><query>index=${TOKEN_METRICS_INDEX} | stats count</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search></single></panel>
  </row>
  <row>
    <panel><title>Tokens by model</title><chart><search><query>index=${TOKEN_METRICS_INDEX} | stats sum(prompt_tokens) as prompt sum(completion_tokens) as completion by model</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search><option name="charting.chart">column</option></chart></panel>
    <panel><title>Tokens by backend</title><chart><search><query>index=${TOKEN_METRICS_INDEX} | stats sum(total_tokens) as total by backend</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search><option name="charting.chart">pie</option></chart></panel>
  </row>
  <row>
    <panel><title>Tokens over time by model</title><chart><search><query>index=${TOKEN_METRICS_INDEX} | timechart sum(total_tokens) by model</query><earliest>\$tr.earliest\$</earliest><latest>\$tr.latest\$</latest></search><option name="charting.chart">line</option></chart></panel>
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

# 1. RESTART so the new index + HEC token are actually loaded (a reload does NOT load a
#    new HEC token — that is what causes "Invalid token"). Bounded so it can't hang.
log "Restarting Splunk to load the index + HEC token (bounded)"
if ! timeout 300 splunk_run restart >/dev/null 2>&1; then
  warn "splunk restart did not finish within 300s; recent splunkd.log:"
  tail -n 40 "${SPLUNK_HOME}/var/log/splunk/splunkd.log" 2>/dev/null | sed 's/^/[splunkd] /' >&2 || true
fi
wait_for_port 127.0.0.1 8089 180 || warn "splunkd mgmt (8089) not up after restart"

# 1b. Verify the index actually materialised on disk (the previous failure mode was an
#     index that existed in config but whose directory was never created, so events were
#     silently unsearchable). Resolve SPLUNK_DB from splunk-launch.conf.
SPLUNK_DB_DIR="$(sed -n 's/^SPLUNK_DB=//p' "${SPLUNK_HOME}/etc/splunk-launch.conf" 2>/dev/null | head -n1)"
SPLUNK_DB_DIR="${SPLUNK_DB_DIR:-\$SPLUNK_HOME/var/lib/splunk}"
SPLUNK_DB_DIR="${SPLUNK_DB_DIR//\$SPLUNK_HOME/${SPLUNK_HOME}}"
# When migrating an existing instance from an app-scoped to a system-scoped index, the
# first restart can race the config change and not materialise the directory. A second
# clean restart with the now-settled config reliably creates it. (Fresh deploys write
# system scope from the start and create it on the first restart.)
if [[ ! -d "${SPLUNK_DB_DIR}/${TOKEN_METRICS_INDEX}" ]]; then
  warn "Index dir not created on first restart; restarting once more to reconcile"
  timeout 300 splunk_run restart >/dev/null 2>&1 || true
  wait_for_port 127.0.0.1 8089 180 || true
fi
if [[ -d "${SPLUNK_DB_DIR}/${TOKEN_METRICS_INDEX}" ]]; then
  log "Index directory present: ${SPLUNK_DB_DIR}/${TOKEN_METRICS_INDEX}"
else
  warn "Index directory STILL MISSING: ${SPLUNK_DB_DIR}/${TOKEN_METRICS_INDEX}"
  warn "Check ownership of ${SPLUNK_DB_DIR} (must be writable by the splunk user)."
fi

# 2. Force-enable global HEC + the token + the index via REST (idempotent).
curl -sk -u "${AUTH}" "${MGMT}/services/data/inputs/http/http" -d disabled=0 -d enableSSL=1 >/dev/null 2>&1 \
  && log "Global HEC enabled" || warn "Could not enable global HEC via REST"
curl -sk -u "${AUTH}" "${MGMT}/services/data/inputs/http/${HEC_TOKEN_NAME}/enable" -X POST >/dev/null 2>&1 || true
curl -sk -u "${AUTH}" "${MGMT}/services/data/indexes/${TOKEN_METRICS_INDEX}/enable" -X POST >/dev/null 2>&1 \
  && log "Index ${TOKEN_METRICS_INDEX} enabled" || warn "Could not enable index via REST"

# 3. Read the ACTUAL registered token back from Splunk (drift-proof source of truth).
REG_TOKEN="$(curl -sk -u "${AUTH}" "${MGMT}/services/data/inputs/http/${HEC_TOKEN_NAME}?output_mode=json" \
  | python3 -c 'import sys,json
e=(json.load(sys.stdin) or {}).get("entry") or []
print(e[0]["content"].get("token","") if e else "")' 2>/dev/null || true)"
if [[ -z "${REG_TOKEN}" ]]; then
  warn "Could not read the registered HEC token back; falling back to the configured value"
  REG_TOKEN="${SPLUNK_HEC_TOKEN}"
fi
log "Registered HEC token: ${REG_TOKEN}"

# 4. Write token-meter.env using the REGISTERED token so the proxy can never disagree.
umask 077
cat > "${METER_ENV_FILE}" <<EOF
HEC_URL=https://127.0.0.1:${HEC_PORT}/services/collector/event
HEC_TOKEN=${REG_TOKEN}
HEC_INDEX=${TOKEN_METRICS_INDEX}
PROXY_API_KEY=${PROXY_API_KEY:-}
EOF
chmod 600 "${METER_ENV_FILE}"

# 5. Self-test end-to-end: post a probe, then SEARCH for it (not just HEC accept). Retry
#    a few times for indexer lag. If it never becomes searchable, dump the exact reason.
log "Self-test: posting a probe event to HEC"
RESP="$(curl -sk "https://127.0.0.1:${HEC_PORT}/services/collector/event" \
  -H "Authorization: Splunk ${REG_TOKEN}" \
  -d "{\"event\":{\"probe\":\"stage11-selftest\"},\"index\":\"${TOKEN_METRICS_INDEX}\",\"sourcetype\":\"token_metrics\"}" 2>/dev/null || true)"
log "HEC response: ${RESP}"
if echo "${RESP}" | grep -q '"code":0'; then
  found=""
  for _try in 1 2 3 4 5 6; do
    sleep 5
    if splunk_run search "search index=${TOKEN_METRICS_INDEX} probe=stage11-selftest earliest=-10m | head 1" 2>/dev/null | grep -q stage11-selftest; then
      found=1; break
    fi
  done
  if [[ -n "${found}" ]]; then
    log "SUCCESS: probe event is searchable in index=${TOKEN_METRICS_INDEX} — metering will land here."
  else
    warn "HEC accepted the probe (code:0) but it is NOT searchable after 30s. Diagnosing:"
    # Did the index receive bytes at all?
    splunk_run search "search index=_internal source=*metrics.log* earliest=-10m per_index_thruput series=${TOKEN_METRICS_INDEX} | stats sum(kb) as kb count" 2>/dev/null | sed 's/^/  [thruput] /' >&2 || true
    # Is the admin role even allowed to search this index?
    ALLOWED="$(curl -sk -u "${AUTH}" "${MGMT}/services/authorization/roles/${SPLUNK_ADMIN_USER}?output_mode=json" \
      | python3 -c 'import sys,json
try:
  c=json.load(sys.stdin)["entry"][0]["content"]; print(",".join(c.get("srchIndexesAllowed") or []))
except Exception: print("")' 2>/dev/null)"
    warn "  role ${SPLUNK_ADMIN_USER} srchIndexesAllowed = [${ALLOWED}]"
    if [[ -n "${ALLOWED}" ]] && ! grep -qE '(^|,)(\*|'"${TOKEN_METRICS_INDEX}"')(,|$)' <<<"${ALLOWED}"; then
      warn "  -> ${TOKEN_METRICS_INDEX} is NOT in that list; the data is indexed but your role can't see it."
      warn "     Grant it in Settings > Roles > ${SPLUNK_ADMIN_USER} > Indexes (add ${TOKEN_METRICS_INDEX}), or set '*'."
    fi
    warn "  If thruput shows bytes but the index dir is missing/0 above, it's an on-disk index problem (permissions/SPLUNK_DB)."
  fi
else
  warn "HEC did NOT accept the probe. Response above. Check the token/index/global-HEC settings."
fi

# 6. Restart the local Ollama metering proxy with the aligned token (host python, no docker).
if [[ -f "${PROXY_APP}" ]] && command -v systemd-run >/dev/null 2>&1; then
  # Upstream: local Ollama if it's here (GPU host), else the GPU host (search head).
  UP=127.0.0.1
  curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1 || UP="${GPU_HOST:-127.0.0.1}"
  log "Restarting Ollama metering proxy :${OLLAMA_PROXY_PORT} -> ${UP}:${OLLAMA_PORT}"
  systemctl stop token-meter-ollama 2>/dev/null || true
  systemctl reset-failed token-meter-ollama 2>/dev/null || true
  systemd-run --unit=token-meter-ollama --collect --property=Restart=always \
    --setenv=UPSTREAM_URL="http://${UP}:${OLLAMA_PORT}" --setenv=BACKEND_LABEL=ollama --setenv=LISTEN_PORT="${OLLAMA_PROXY_PORT}" \
    --setenv=HEC_URL="https://127.0.0.1:${HEC_PORT}/services/collector/event" \
    --setenv=HEC_TOKEN="${REG_TOKEN}" --setenv=HEC_INDEX="${TOKEN_METRICS_INDEX}" \
    --setenv=HEC_VERIFY_TLS=false --setenv=DEFAULT_APP="${DEFAULT_APP}" \
    python3 "${PROXY_APP}" \
    && log "Ollama metering proxy restarted with the aligned HEC token" \
    || warn "Could not restart the Ollama proxy; start it manually"
else
  warn "Proxy app not found at ${PROXY_APP}; skipping proxy restart"
fi

log "Done. token_metrics index active, HEC token aligned, proxy restarted."
log "Verify: curl -s http://localhost:${OLLAMA_PROXY_PORT}/api/chat -d '{\"model\":\"foundation-sec-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false}' >/dev/null ; then search index=${TOKEN_METRICS_INDEX}"
