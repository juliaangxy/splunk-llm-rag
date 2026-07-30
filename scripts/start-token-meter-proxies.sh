#!/usr/bin/env bash
set -euo pipefail

# Start the token-metering proxies in front of vLLM and Ollama on the GPU host.
# NOT run automatically during deployment — run this when you want token counting on.
# After starting, point Splunk at the proxies:  sudo ./configure-splunk-llm.sh --mode proxy
#
# Reads HEC settings from /opt/splunk-ai/token-meter.env (written by 11-token-metrics.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

METER_ENV_FILE="${METER_ENV_FILE:-/opt/splunk-ai/token-meter.env}"
if [[ -f "${METER_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "${METER_ENV_FILE}"; set +a
fi

TOKEN_METER_PROXY_IMAGE="${TOKEN_METER_PROXY_IMAGE:-token-meter-proxy:latest}"
# Where the models actually run. On the GPU host this is loopback; on the search head
# set it to the GPU host's IP (GPU_HOST is exported into bootstrap.env there) so the
# LOCAL proxy forwards to the remote models but still ships metrics to the LOCAL HEC —
# i.e. usage is recorded on whichever instance initiated the call.
UPSTREAM_HOST="${UPSTREAM_HOST:-${GPU_HOST:-127.0.0.1}}"
VLLM_PORT="${VLLM_PORT:-8001}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
VLLM_PROXY_PORT="${VLLM_PROXY_PORT:-8100}"
OLLAMA_PROXY_PORT="${OLLAMA_PROXY_PORT:-8101}"
HEC_URL="${HEC_URL:-}"
HEC_TOKEN="${HEC_TOKEN:-}"
HEC_INDEX="${HEC_INDEX:-token_metrics}"
PROXY_API_KEY="${PROXY_API_KEY:-}"
# Optional per-model/-source HEC routing table (see configure-token-meter-routes.sh).
# When present, the proxy ships each call's metric to the destination the table selects;
# HEC_URL/HEC_TOKEN above stay as the fallback default. Empty when the file is absent.
HEC_ROUTES_FILE="${HEC_ROUTES_FILE:-/opt/splunk-ai/token-meter-routes.json}"
[[ -f "${HEC_ROUTES_FILE}" ]] || HEC_ROUTES_FILE=""
[[ -n "${HEC_ROUTES_FILE}" ]] && log "Using HEC routing table ${HEC_ROUTES_FILE}"
# Source label recorded on each metric (AITK doesn't forward Splunk's user/app to the model).
DEFAULT_APP="${DEFAULT_APP:-Splunk_ML_Toolkit}"

PROXY_APP="${PROXY_APP:-/opt/splunk-ai/token-meter-proxy/app.py}"

run_proxy() {
  local name="$1" listen="$2" upstream="$3" label="$4" api_key="${5:-}"

  # Preferred: run the stdlib proxy from the staged files via host python — no Docker,
  # no registry/ECR, works identically in cloud and airgapped.
  if [[ -f "${PROXY_APP}" ]] && command -v python3 >/dev/null 2>&1; then
    systemctl stop "${name}" 2>/dev/null || true
    systemctl reset-failed "${name}" 2>/dev/null || true
    log "Starting ${name} via host python (:${listen} -> ${upstream}, label=${label})"
    systemd-run --unit="${name}" --collect --property=Restart=always \
      --setenv=UPSTREAM_URL="${upstream}" --setenv=BACKEND_LABEL="${label}" --setenv=LISTEN_PORT="${listen}" \
      --setenv=HEC_URL="${HEC_URL}" --setenv=HEC_TOKEN="${HEC_TOKEN}" --setenv=HEC_INDEX="${HEC_INDEX}" \
      --setenv=HEC_ROUTES_FILE="${HEC_ROUTES_FILE}" \
      --setenv=HEC_VERIFY_TLS="false" --setenv=PROXY_API_KEY="${api_key}" --setenv=DEFAULT_APP="${DEFAULT_APP}" \
      python3 "${PROXY_APP}"
    wait_for_port 127.0.0.1 "${listen}" 60
    return 0
  fi

  # Fallback: container image (requires the image to be pullable from a registry/ECR).
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
    "${TOKEN_METER_PROXY_IMAGE}" >/dev/null
  wait_for_port 127.0.0.1 "${listen}" 120
}

# vLLM/OpenAI: AITK sends llm_openai_api_key as a Bearer token, so require it.
# Ollama: clients (incl. AITK's Ollama provider) send no key, so run the proxy keyless
# — requiring a key here would 401 every Ollama call and record nothing.
run_proxy "token-meter-vllm"   "${VLLM_PROXY_PORT}"   "http://${UPSTREAM_HOST}:${VLLM_PORT}"   "vllm"   "${PROXY_API_KEY}"
run_proxy "token-meter-ollama" "${OLLAMA_PROXY_PORT}" "http://${UPSTREAM_HOST}:${OLLAMA_PORT}" "ollama" ""

log "Token-metering proxies running (vLLM :${VLLM_PROXY_PORT}, Ollama :${OLLAMA_PROXY_PORT})."
log "Now point Splunk at them:  sudo ${SCRIPT_DIR}/configure-splunk-llm.sh --mode proxy"
