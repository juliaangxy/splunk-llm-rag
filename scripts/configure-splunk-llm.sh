#!/usr/bin/env bash
set -euo pipefail

# Write mltk-container/local/llm.conf so DSDL / AITK call the models via either the
# model servers DIRECTLY (default) or via the token-metering PROXY (to record token
# usage). Used by the 09-configure stages (direct) and runnable manually to switch to
# proxy mode:  sudo ./configure-splunk-llm.sh --mode proxy
#
# Env inputs (defaults shown):
#   GPU_HOST=127.0.0.1        host where vLLM/Ollama/proxy run (search head sets the GPU private IP)
#   VLLM_PORT=8001            OLLAMA_PORT=11434
#   VLLM_PROXY_PORT=8100      OLLAMA_PROXY_PORT=8101
#   VLLM_MODEL_NAME=granite-3.1-2b-instruct    PROXY_API_KEY=...
#   OLLAMA_DEFAULT_MODEL=foundation-sec-8b

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

MODE="direct"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ "${MODE}" == "direct" || "${MODE}" == "proxy" ]] || { echo "mode must be direct|proxy" >&2; exit 2; }

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
GPU_HOST="${GPU_HOST:-127.0.0.1}"
VLLM_PORT="${VLLM_PORT:-8001}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
VLLM_PROXY_PORT="${VLLM_PROXY_PORT:-8100}"
OLLAMA_PROXY_PORT="${OLLAMA_PROXY_PORT:-8101}"
VLLM_MODEL_NAME="${VLLM_MODEL_NAME:-granite-3.1-2b-instruct}"
OLLAMA_DEFAULT_MODEL="${OLLAMA_DEFAULT_MODEL:-foundation-sec-8b}"
PROXY_API_KEY="${PROXY_API_KEY:-EMPTY}"

# The token-metering proxy runs LOCALLY on each instance (it forwards to the models,
# which may be remote, and posts metrics to this instance's own HEC). So in proxy mode
# AITK targets the local proxy, not the GPU host. Direct mode targets the models.
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
if [[ "${MODE}" == "proxy" ]]; then
  OPENAI_BASE_URL="http://${PROXY_HOST}:${VLLM_PROXY_PORT}/v1"
  OLLAMA_BASE_URL="http://${PROXY_HOST}:${OLLAMA_PROXY_PORT}"
  OPENAI_API_KEY="${PROXY_API_KEY}"
else
  OPENAI_BASE_URL="http://${GPU_HOST}:${VLLM_PORT}/v1"
  OLLAMA_BASE_URL="http://${GPU_HOST}:${OLLAMA_PORT}"
  OPENAI_API_KEY="EMPTY"
fi

LLM_LOCAL_DIR="${SPLUNK_HOME}/etc/apps/mltk-container/local"
mkdir -p "${LLM_LOCAL_DIR}"

# Only the provider keys we manage; Splunk merges these over default/llm.conf.
cat > "${LLM_LOCAL_DIR}/llm.conf" <<EOF
[llm_config]
llm_ollama_is_configured = true
llm_ollama_model = ${OLLAMA_DEFAULT_MODEL}
llm_ollama_base_url = ${OLLAMA_BASE_URL}
llm_openai_is_configured = true
llm_openai_model = ${VLLM_MODEL_NAME}
llm_openai_base_url = ${OPENAI_BASE_URL}
llm_openai_api_key = ${OPENAI_API_KEY}
EOF

if id -u splunk >/dev/null 2>&1; then
  chown splunk:splunk "${LLM_LOCAL_DIR}/llm.conf"
fi
chmod 0644 "${LLM_LOCAL_DIR}/llm.conf"
log "Wrote ${LLM_LOCAL_DIR}/llm.conf (mode=${MODE}): openai=${OPENAI_BASE_URL} model=${VLLM_MODEL_NAME}, ollama=${OLLAMA_BASE_URL}"

# Reload the app that owns llm.conf so DSDL/AITK pick up the new endpoints now.
# (`splunk reload app` is not a valid CLI command; use the app _reload REST endpoint.)
if splunk_run _internal call /services/apps/local/mltk-container/_reload -method POST >/dev/null 2>&1; then
  log "Reloaded mltk-container; new LLM endpoints are active"
else
  warn "Could not reload mltk-container via REST; reload/restart Splunk for the new LLM endpoints to take effect"
fi
