#!/usr/bin/env bash
set -euo pipefail

# Deploy a small-but-capable Granite model on vLLM (OpenAI-compatible) on the GPU host,
# and run the token-metering proxies in front of vLLM and Ollama so all token usage is
# recorded to the token_metrics index. GPU host only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

DEPLOY_VLLM="${DEPLOY_VLLM:-true}"
DEPLOY_TOKEN_METER_PROXY="${DEPLOY_TOKEN_METER_PROXY:-false}"
if [[ "${DEPLOY_VLLM}" != "true" && "${DEPLOY_TOKEN_METER_PROXY}" != "true" ]]; then
  log "DEPLOY_VLLM=${DEPLOY_VLLM} and DEPLOY_TOKEN_METER_PROXY=${DEPLOY_TOKEN_METER_PROXY}; skipping vLLM/proxy deployment"
  exit 0
fi

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:latest}"
VLLM_CONTAINER_NAME="${VLLM_CONTAINER_NAME:-vllm}"
VLLM_PORT="${VLLM_PORT:-8001}"
VLLM_MODEL="${VLLM_MODEL:-ibm-granite/granite-3.1-2b-instruct}"
VLLM_MODEL_NAME="${VLLM_MODEL_NAME:-granite-3.1-2b-instruct}"
# Defaults sized for a 16 GB T4 SHARED with Ollama: cap vLLM at ~40% and a modest
# context so it coexists without CUDA OOM. Override per-deploy if you have more VRAM.
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-4096}"
VLLM_GPU_MEM_UTIL="${VLLM_GPU_MEM_UTIL:-0.40}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"
VLLM_MODEL_S3_PREFIX="${VLLM_MODEL_S3_PREFIX:-models/vllm/${VLLM_MODEL_NAME}/}"
VLLM_MODEL_DIR="${VLLM_MODEL_DIR:-/opt/splunk-ai/models/vllm/${VLLM_MODEL_NAME}}"
AI_ARTIFACTS_BUCKET="${AI_ARTIFACTS_BUCKET:-}"
HF_TOKEN="${HF_TOKEN:-}"

TOKEN_METER_PROXY_IMAGE="${TOKEN_METER_PROXY_IMAGE:-token-meter-proxy:latest}"
# DEPLOY_TOKEN_METER_PROXY (resolved at the top of this script) controls whether the
# metering proxies are started and wired into Splunk here. When false they are only
# staged (image + files) for a manual start via start-token-meter-proxies.sh.

# --- Resolve the vLLM model source: local (airgapped/S3) or Hugging Face id ---
resolve_model_source() {
  if is_airgapped || [[ -n "${AI_ARTIFACTS_BUCKET}" && "${VLLM_MODEL_SOURCE_MODE:-auto}" == "s3" ]]; then
    require_cmd aws
    mkdir -p "${VLLM_MODEL_DIR}"
    local uri="s3://${AI_ARTIFACTS_BUCKET}/${VLLM_MODEL_S3_PREFIX}"
    log "Syncing vLLM model from ${uri}"
    if aws s3 sync "${uri}" "${VLLM_MODEL_DIR}" --only-show-errors && [[ -n "$(ls -A "${VLLM_MODEL_DIR}" 2>/dev/null)" ]]; then
      MODEL_ARG="/models"
      MODEL_MOUNT=(-v "${VLLM_MODEL_DIR}:/models:ro")
      return 0
    fi
    if is_airgapped; then
      error "Airgapped: vLLM model not found at ${uri}; pre-stage it before deploying"
      return 1
    fi
    warn "S3 model sync empty; falling back to Hugging Face id ${VLLM_MODEL}"
  fi
  MODEL_ARG="${VLLM_MODEL}"
  MODEL_MOUNT=()
}

run_vllm() {
  ensure_image "${VLLM_IMAGE}"
  if docker ps -a --format '{{.Names}}' | grep -qx "${VLLM_CONTAINER_NAME}"; then
    docker rm -f "${VLLM_CONTAINER_NAME}" >/dev/null
  fi
  local hf_env=()
  [[ -n "${HF_TOKEN}" ]] && hf_env=(-e "HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}")

  log "Starting vLLM (${VLLM_MODEL_NAME}) on port ${VLLM_PORT} from model source ${MODEL_ARG}"
  docker run -d --name "${VLLM_CONTAINER_NAME}" \
    --gpus all --restart unless-stopped \
    -p "${VLLM_PORT}:8000" \
    -v vllm-cache:/root/.cache/huggingface \
    "${MODEL_MOUNT[@]}" "${hf_env[@]}" \
    "${VLLM_IMAGE}" \
    --model "${MODEL_ARG}" \
    --served-model-name "${VLLM_MODEL_NAME}" \
    --max-model-len "${VLLM_MAX_MODEL_LEN}" \
    --gpu-memory-utilization "${VLLM_GPU_MEM_UTIL}" \
    ${VLLM_EXTRA_ARGS} >/dev/null

  wait_for_port 127.0.0.1 "${VLLM_PORT}" 600
  # First-run warmup can be long (multi-GB HF download + torch.compile + CUDA graphs),
  # and vLLM resets connections until ready — allow ~10 min of readiness polling.
  retry 60 10 curl -fsS "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null
  log "vLLM is serving ${VLLM_MODEL_NAME} on port ${VLLM_PORT}"
}

# Make the proxy image available locally so it can be started manually later (no run).
stage_token_meter_proxy() {
  if ! ensure_image "${TOKEN_METER_PROXY_IMAGE}"; then
    warn "Could not pre-pull token-meter proxy image ${TOKEN_METER_PROXY_IMAGE}; it is staged as files under /opt/splunk-ai/token-meter-proxy"
  fi
  if [[ -d /opt/splunk-ai/token-meter-proxy ]]; then
    log "token-meter proxy files staged at /opt/splunk-ai/token-meter-proxy"
  fi
}

MODEL_ARG=""
declare -a MODEL_MOUNT=()
if [[ "${DEPLOY_VLLM}" == "true" ]]; then
  resolve_model_source
  run_vllm
else
  log "DEPLOY_VLLM=false; skipping the vLLM server (proxy handling below still applies)"
fi
stage_token_meter_proxy

if [[ "${DEPLOY_TOKEN_METER_PROXY}" == "true" ]]; then
  log "DEPLOY_TOKEN_METER_PROXY=true; starting the token-metering proxies now"
  # Generate the HEC routing table first (defaults to shipping usage to the search head)
  # so the proxies come up already pointing metrics at the chosen Splunk instance.
  TOKEN_METER_ROUTES="${TOKEN_METER_ROUTES:-[]}" \
  TOKEN_METER_DEFAULT_ROLE="${TOKEN_METER_DEFAULT_ROLE:-search-head}" \
    bash "${SCRIPT_DIR}/configure-token-meter-routes.sh" || warn "token-meter route generation failed (non-fatal); using single-HEC default"
  bash "${SCRIPT_DIR}/start-token-meter-proxies.sh"
  bash "${SCRIPT_DIR}/configure-splunk-llm.sh" --mode proxy || true
else
  log "vLLM is serving on :${VLLM_PORT}. Token-metering proxy is staged but NOT started."
  log "To enable token counting: sudo ${SCRIPT_DIR}/start-token-meter-proxies.sh && sudo ${SCRIPT_DIR}/configure-splunk-llm.sh --mode proxy"
fi
