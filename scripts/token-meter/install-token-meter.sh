#!/usr/bin/env bash
set -euo pipefail

# One-shot token-metering installer. Run it on the Splunk host after copying the files into
# /opt/splunk-ai (see TOKEN-METERING-INSTALL.md). It:
#   1. AUTO-DISCOVERS which model backends (Ollama / vLLM-OpenAI) are running on --model-host,
#   2. sets up the token_metrics index + HEC on --metric-host (or ships to a remote one), and
#   3. starts a metering proxy in front of each discovered backend.
#
# Usage (a bare run does a same-host, all-local install):
#   sudo ./install-token-meter.sh [--metric-host <splunk-host>] [--model-host <model-host>] \
#        [--ollama-proxy-port 8101] [--vllm-proxy-port 8100] \
#        [--ollama-port 11434] [--vllm-port 8001] [--hec-port 8088] [--hec-token <token>]
#
# Hosts (both default to localhost):
#   --metric-host   Splunk instance that stores the metrics (its HEC). Default localhost:
#                   the index + HEC token are created here (needs SPLUNK_ADMIN_PASSWORD in
#                   the environment). For a REMOTE Splunk, pass its host + --hec-token for a
#                   token already registered there (run this installer on that host first).
#   --model-host    Host where Ollama and/or vLLM run (default localhost). Probed to auto-detect.
#
# Optional:
#   --ollama-proxy-port / --vllm-proxy-port   proxy LISTEN ports clients call (default 8101 / 8100)
#   --ollama-port / --vllm-port               model ports to probe/forward to (default 11434 / 8001)
#   --hec-port                                Splunk HEC port (default 8088)
#   --hec-token                               HEC token (required only for a REMOTE --metric-host)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
require_root

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

METRIC_HOST="localhost"; MODEL_HOST="localhost"   # same-host install by default; override for remote
OLLAMA_PORT=11434; VLLM_PORT=8001
OLLAMA_PROXY_PORT=8101; VLLM_PROXY_PORT=8100
HEC_PORT=8088; HEC_TOKEN_ARG=""
TOKEN_METRICS_INDEX="${TOKEN_METRICS_INDEX:-token_metrics}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --metric-host)        METRIC_HOST="${2:-}"; shift 2;;
    --model-host)         MODEL_HOST="${2:-}"; shift 2;;
    --ollama-proxy-port)  OLLAMA_PROXY_PORT="${2:-}"; shift 2;;
    --vllm-proxy-port)    VLLM_PROXY_PORT="${2:-}"; shift 2;;
    --ollama-port)        OLLAMA_PORT="${2:-}"; shift 2;;
    --vllm-port)          VLLM_PORT="${2:-}"; shift 2;;
    --hec-port)           HEC_PORT="${2:-}"; shift 2;;
    --hec-token)          HEC_TOKEN_ARG="${2:-}"; shift 2;;
    -h|--help)            usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done
# --metric-host / --model-host default to localhost above; a bare run does a same-host install.
if [[ -z "${METRIC_HOST}" || -z "${MODEL_HOST}" ]]; then
  echo "ERROR: --metric-host / --model-host cannot be empty" >&2; usage; exit 2
fi

is_local_host() {
  local h="$1" ip
  [[ "${h}" == localhost || "${h}" == 127.0.0.1 || "${h}" == ::1 ]] && return 0
  for ip in $(hostname -I 2>/dev/null); do [[ "${h}" == "${ip}" ]] && return 0; done
  [[ "${h}" == "$(hostname -f 2>/dev/null)" || "${h}" == "$(hostname 2>/dev/null)" ]] && return 0
  return 1
}

# 1. Discover which backends are actually running on the model host.
log "Discovering model backends on ${MODEL_HOST} ..."
OLLAMA_UP=""; VLLM_UP=""
curl -sf -m 5 "http://${MODEL_HOST}:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1 && OLLAMA_UP=1
curl -sf -m 5 "http://${MODEL_HOST}:${VLLM_PORT}/v1/models"  >/dev/null 2>&1 && VLLM_UP=1
[[ -n "${OLLAMA_UP}" ]] && log "  ✓ Ollama detected at ${MODEL_HOST}:${OLLAMA_PORT}"
[[ -n "${VLLM_UP}"   ]] && log "  ✓ vLLM/OpenAI detected at ${MODEL_HOST}:${VLLM_PORT}"
if [[ -z "${OLLAMA_UP}" && -z "${VLLM_UP}" ]]; then
  error "No Ollama (:${OLLAMA_PORT}) or vLLM (:${VLLM_PORT}) reachable on ${MODEL_HOST}. Check the host/ports (--ollama-port/--vllm-port) and that the models are up."
  exit 1
fi

# 2. Tell the proxy launcher which backends to start (empty upstream URL => that proxy is
#    skipped) and where the models live, plus the proxy listen ports.
export OLLAMA_PROXY_PORT VLLM_PROXY_PORT TOKEN_METRICS_INDEX
export OLLAMA_UPSTREAM_URL="" VLLM_UPSTREAM_URL=""
[[ -n "${OLLAMA_UP}" ]] && export OLLAMA_UPSTREAM_URL="http://${MODEL_HOST}:${OLLAMA_PORT}"
[[ -n "${VLLM_UP}"   ]] && export VLLM_UPSTREAM_URL="http://${MODEL_HOST}:${VLLM_PORT}"

# 3. Create (local) or point at (remote) the metric receiver, then start the proxies.
if is_local_host "${METRIC_HOST}"; then
  log "Metric host is local — creating the ${TOKEN_METRICS_INDEX} index + HEC on this Splunk"
  require_env SPLUNK_ADMIN_PASSWORD
  export HEC_PORT
  # 11 creates the index + HEC (restart-until-searchable), writes token-meter.env, and — via
  # the exported upstream/port vars above — starts the proxies for the discovered backends
  # shipping to the LOCAL HEC.
  bash "${SCRIPT_DIR}/../11-token-metrics.sh"
else
  log "Metric host ${METRIC_HOST} is remote — shipping to its HEC (index + HEC must already exist there)"
  [[ -n "${HEC_TOKEN_ARG}" ]] || { error "--hec-token is required for a remote --metric-host (run this installer on ${METRIC_HOST} first to create + read it)"; exit 1; }
  export HEC_URL="https://${METRIC_HOST}:${HEC_PORT}/services/collector/event"
  export HEC_TOKEN="${HEC_TOKEN_ARG}"
  export HEC_INDEX="${TOKEN_METRICS_INDEX}"
  bash "${SCRIPT_DIR}/start-token-meter-proxies.sh"
fi

echo
log "Done. Point clients at the proxies on THIS host:"
[[ -n "${OLLAMA_UP}" ]] && log "  Ollama       -> http://<this-host>:${OLLAMA_PROXY_PORT}"
[[ -n "${VLLM_UP}"   ]] && log "  OpenAI/vLLM  -> http://<this-host>:${VLLM_PROXY_PORT}/v1  (API key = PROXY_API_KEY in /opt/splunk-ai/token-meter.env)"
log "  View usage in Splunk on ${METRIC_HOST}:  index=${TOKEN_METRICS_INDEX}   (or Apps → AI Token Usage)"
