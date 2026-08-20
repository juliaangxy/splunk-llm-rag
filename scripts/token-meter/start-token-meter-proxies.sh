#!/usr/bin/env bash
set -euo pipefail

# Start the token-metering proxies in front of vLLM and/or Ollama.
# Usually invoked by install-token-meter.sh; run directly to (re)start with custom endpoints.
# After starting, point clients/AITK at the proxies (or: ./configure-splunk-llm.sh --mode proxy).
#
# Reads HEC settings from /opt/splunk-ai/token-meter.env (written by 11-token-metrics.sh);
# env values (HEC_URL/HEC_TOKEN, OLLAMA_UPSTREAM_URL/VLLM_UPSTREAM_URL) override the file.
#
# How each proxy is launched (first that fits): a systemd unit (host python, Restart=always) on
# systemd hosts; else a backgrounded `python3 app.py` (no systemd — e.g. macOS/dev; PID+log under
# TOKEN_METER_RUN_DIR, no auto-restart); else a container image (TOKEN_METER_PROXY_IMAGE).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# systemd + container paths need root; the no-systemd host-python fallback does not — so only
# require root when systemd is present (keeps it runnable unprivileged on macOS/dev).
if command -v systemctl >/dev/null 2>&1; then
  require_root
fi

# --- User-definable endpoints -------------------------------------------------
# Both the MODEL base URLs (what the proxy forwards to) and the METRIC RECEIVER
# (Splunk HEC) can be set via env, so the proxy, the models, and Splunk can each
# live anywhere. Env values WIN over token-meter.env.
#   Models   : OLLAMA_UPSTREAM_URL / VLLM_UPSTREAM_URL   (full base URLs), or the
#              older UPSTREAM_HOST + OLLAMA_PORT / VLLM_PORT (host+port) shorthand.
#   Receiver : HEC_URL / HEC_TOKEN / HEC_INDEX  (the Splunk HTTP Event Collector).
METER_ENV_FILE="${METER_ENV_FILE:-/opt/splunk-ai/token-meter.env}"
# Capture env-provided overrides BEFORE sourcing the file so they take precedence.
_ov_HEC_URL="${HEC_URL:-}"; _ov_HEC_TOKEN="${HEC_TOKEN:-}"; _ov_HEC_INDEX="${HEC_INDEX:-}"
_ov_PROXY_API_KEY="${PROXY_API_KEY:-}"
if [[ -f "${METER_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "${METER_ENV_FILE}"; set +a
fi
# Env override > token-meter.env value > default.
HEC_URL="${_ov_HEC_URL:-${HEC_URL:-}}"
HEC_TOKEN="${_ov_HEC_TOKEN:-${HEC_TOKEN:-}}"
HEC_INDEX="${_ov_HEC_INDEX:-${HEC_INDEX:-token_metrics}}"
PROXY_API_KEY="${_ov_PROXY_API_KEY:-${PROXY_API_KEY:-}}"

TOKEN_METER_PROXY_IMAGE="${TOKEN_METER_PROXY_IMAGE:-token-meter-proxy:latest}"
# Model host+port — used only to CONSTRUCT the default upstream URLs below. Set UPSTREAM_HOST
# to the model host's address when the models run elsewhere; defaults to loopback. (GPU_HOST
# is honored as a fallback for the AWS platform, where its search head exports it.)
UPSTREAM_HOST="${UPSTREAM_HOST:-${GPU_HOST:-127.0.0.1}}"
VLLM_PORT="${VLLM_PORT:-8001}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
VLLM_PROXY_PORT="${VLLM_PROXY_PORT:-8100}"
OLLAMA_PROXY_PORT="${OLLAMA_PROXY_PORT:-8101}"
# Full model base URLs the proxy forwards to. Set these directly for a non-default
# scheme/host/path/port; otherwise built from UPSTREAM_HOST + the ports above. Note the
# single-dash `-` (not `:-`): an explicitly EMPTY value is preserved and SKIPS that proxy
# (how install-token-meter.sh starts only the backends it discovered); UNSET → default.
OLLAMA_UPSTREAM_URL="${OLLAMA_UPSTREAM_URL-http://${UPSTREAM_HOST}:${OLLAMA_PORT}}"
VLLM_UPSTREAM_URL="${VLLM_UPSTREAM_URL-http://${UPSTREAM_HOST}:${VLLM_PORT}}"
# Optional HEC destination file (written by configure-token-meter-routes.sh). When present,
# the proxy ships metrics to the Splunk it names (e.g. the GPU host -> search head); when
# absent, the HEC_URL/HEC_TOKEN above are used directly.
HEC_ROUTES_FILE="${HEC_ROUTES_FILE:-/opt/splunk-ai/token-meter-routes.json}"
[[ -f "${HEC_ROUTES_FILE}" ]] || HEC_ROUTES_FILE=""
[[ -n "${HEC_ROUTES_FILE}" ]] && log "Using HEC destination file ${HEC_ROUTES_FILE}"
# Source label recorded on each metric (AITK doesn't forward Splunk's user/app to the model).
DEFAULT_APP="${DEFAULT_APP:-Splunk_ML_Toolkit}"
# Optional content logging (OFF by default). Set LOG_PROMPT/LOG_COMPLETION=true to also record the
# prompt/response TEXT in each metric — see the privacy/volume warning in the README.
LOG_PROMPT="${LOG_PROMPT:-false}"
LOG_COMPLETION="${LOG_COMPLETION:-false}"
MAX_CONTENT_CHARS="${MAX_CONTENT_CHARS:-2000}"

PROXY_APP="${PROXY_APP:-/opt/splunk-ai/scripts/token-meter/token-meter-proxy/app.py}"
# PID + log directory for the no-systemd (backgrounded) host-python fallback (e.g. macOS/dev).
TOKEN_METER_RUN_DIR="${TOKEN_METER_RUN_DIR:-/tmp/token-meter}"

# No-systemd fallback: run the proxy as a plain backgrounded host process (e.g. macOS/dev). Records
# a PID + log under TOKEN_METER_RUN_DIR so a re-run can stop the previous one; no auto-restart.
run_proxy_bg() {
  local name="$1" listen="$2" upstream="$3" label="$4" api_key="${5:-}"
  mkdir -p "${TOKEN_METER_RUN_DIR}"
  local pidf="${TOKEN_METER_RUN_DIR}/${name}.pid" logf="${TOKEN_METER_RUN_DIR}/${name}.log"
  # Stop a previous instance we started (best-effort).
  if [[ -f "${pidf}" ]]; then
    local oldpid; oldpid="$(cat "${pidf}" 2>/dev/null || true)"
    [[ -n "${oldpid}" ]] && kill "${oldpid}" 2>/dev/null || true
    rm -f "${pidf}"
  fi
  log "Starting ${name} via host python (no systemd; backgrounded) (:${listen} -> ${upstream}, label=${label})"
  UPSTREAM_URL="${upstream}" BACKEND_LABEL="${label}" LISTEN_PORT="${listen}" \
  HEC_URL="${HEC_URL}" HEC_TOKEN="${HEC_TOKEN}" HEC_INDEX="${HEC_INDEX}" \
  HEC_ROUTES_FILE="${HEC_ROUTES_FILE}" HEC_VERIFY_TLS="false" \
  PROXY_API_KEY="${api_key}" DEFAULT_APP="${DEFAULT_APP}" \
  LOG_PROMPT="${LOG_PROMPT}" LOG_COMPLETION="${LOG_COMPLETION}" MAX_CONTENT_CHARS="${MAX_CONTENT_CHARS}" \
    nohup python3 "${PROXY_APP}" >"${logf}" 2>&1 &
  echo "$!" > "${pidf}"
  log "  ${name}: pid $(cat "${pidf}"), log ${logf}  (stop: kill \$(cat ${pidf}))"
}

run_proxy() {
  local name="$1" listen="$2" upstream="$3" label="$4" api_key="${5:-}"

  # Preferred: run the stdlib proxy from the staged files via host python — no Docker,
  # no registry/ECR, works identically in cloud and airgapped.
  if [[ -f "${PROXY_APP}" ]] && command -v python3 >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1; then
      # systemd host: managed unit with Restart=always.
      systemctl stop "${name}" 2>/dev/null || true
      systemctl reset-failed "${name}" 2>/dev/null || true
      log "Starting ${name} via host python + systemd (:${listen} -> ${upstream}, label=${label})"
      systemd-run --unit="${name}" --collect --property=Restart=always \
        --setenv=UPSTREAM_URL="${upstream}" --setenv=BACKEND_LABEL="${label}" --setenv=LISTEN_PORT="${listen}" \
        --setenv=HEC_URL="${HEC_URL}" --setenv=HEC_TOKEN="${HEC_TOKEN}" --setenv=HEC_INDEX="${HEC_INDEX}" \
        --setenv=HEC_ROUTES_FILE="${HEC_ROUTES_FILE}" \
        --setenv=HEC_VERIFY_TLS="false" --setenv=PROXY_API_KEY="${api_key}" --setenv=DEFAULT_APP="${DEFAULT_APP}" \
        --setenv=LOG_PROMPT="${LOG_PROMPT}" --setenv=LOG_COMPLETION="${LOG_COMPLETION}" --setenv=MAX_CONTENT_CHARS="${MAX_CONTENT_CHARS}" \
        python3 "${PROXY_APP}"
    else
      # No systemd (macOS/dev): run app.py as a backgrounded host process.
      run_proxy_bg "${name}" "${listen}" "${upstream}" "${label}" "${api_key}"
    fi
    wait_for_port 127.0.0.1 "${listen}" 60
    return 0
  fi

  # Fallback: container image — only meaningful when TOKEN_METER_PROXY_IMAGE is a real registry
  # ref (contains a registry host, i.e. a "/"). The bare default `token-meter-proxy:latest` has
  # no registry and would resolve to Docker Hub (which has no such image) — so if the staged
  # app.py is missing and no real image was configured, fail with a clear, actionable message
  # instead of a confusing "pull access denied".
  if [[ "${TOKEN_METER_PROXY_IMAGE}" != */* ]]; then
    error "Proxy app not found at ${PROXY_APP} (python3: $(command -v python3 || echo missing))."
    error "Re-copy scripts/token-meter/token-meter-proxy/app.py to ${PROXY_APP}, or set TOKEN_METER_PROXY_IMAGE to a pullable registry ref."
    return 1
  fi
  log "Host python/app unavailable; falling back to container image ${TOKEN_METER_PROXY_IMAGE}"
  ensure_image "${TOKEN_METER_PROXY_IMAGE}"
  if docker ps -a --format '{{.Names}}' | grep -qx "${name}"; then
    docker rm -f "${name}" >/dev/null
  fi
  log "Starting ${name} (:${listen} -> ${upstream}, label=${label})"
  local routes_mount=() routes_env=()
  if [[ -n "${HEC_ROUTES_FILE}" ]]; then
    routes_mount=(-v "${HEC_ROUTES_FILE}:${HEC_ROUTES_FILE}:ro")
    routes_env=(-e "HEC_ROUTES_FILE=${HEC_ROUTES_FILE}")
  fi
  docker run -d --name "${name}" --restart unless-stopped --network host \
    -e "UPSTREAM_URL=${upstream}" -e "BACKEND_LABEL=${label}" -e "LISTEN_PORT=${listen}" \
    -e "HEC_URL=${HEC_URL}" -e "HEC_TOKEN=${HEC_TOKEN}" -e "HEC_INDEX=${HEC_INDEX}" \
    "${routes_env[@]}" "${routes_mount[@]}" \
    -e "HEC_VERIFY_TLS=false" -e "PROXY_API_KEY=${api_key}" -e "DEFAULT_APP=${DEFAULT_APP}" \
    -e "LOG_PROMPT=${LOG_PROMPT}" -e "LOG_COMPLETION=${LOG_COMPLETION}" -e "MAX_CONTENT_CHARS=${MAX_CONTENT_CHARS}" \
    "${TOKEN_METER_PROXY_IMAGE}" >/dev/null
  wait_for_port 127.0.0.1 "${listen}" 120
}

# vLLM/OpenAI: AITK sends llm_openai_api_key as a Bearer token, so require it.
# Ollama: clients (incl. AITK's Ollama provider) send no key, so run the proxy keyless
# — requiring a key here would 401 every Ollama call and record nothing.
if [[ -n "${VLLM_UPSTREAM_URL}" ]]; then
  run_proxy "token-meter-vllm" "${VLLM_PROXY_PORT}" "${VLLM_UPSTREAM_URL}" "vllm" "${PROXY_API_KEY}"
else
  log "VLLM_UPSTREAM_URL empty — skipping vLLM proxy"
  systemctl stop token-meter-vllm 2>/dev/null || true
fi
if [[ -n "${OLLAMA_UPSTREAM_URL}" ]]; then
  run_proxy "token-meter-ollama" "${OLLAMA_PROXY_PORT}" "${OLLAMA_UPSTREAM_URL}" "ollama" ""
else
  log "OLLAMA_UPSTREAM_URL empty — skipping Ollama proxy"
  systemctl stop token-meter-ollama 2>/dev/null || true
fi

log "Token-metering proxies running (vLLM :${VLLM_PROXY_PORT}, Ollama :${OLLAMA_PROXY_PORT})."
log "Now point Splunk at them:  sudo ${SCRIPT_DIR}/configure-splunk-llm.sh --mode proxy"
