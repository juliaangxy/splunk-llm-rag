#!/usr/bin/env bash
set -euo pipefail

# Simulate MULTIPLE search heads sending AI commands through ONE token-meter proxy on the GPU host.
# Each simulated search head tags its calls with X-Splunk-Origin, so the single proxy attributes
# every metric to its source search head and pipes them ALL into the same token_metrics index
# (on the remote receiving search head the proxy is configured to ship to).
#
#   many search heads ─▶ one proxy (GPU host, :8100/:8101) ─▶ models
#                                     └─ one metric per call ─▶ remote SH HEC ─▶ index=token_metrics
#
# Prereq: the proxy is deployed on the GPU host and forwards to a real model (Ollama/vLLM), and it
# ships metrics to the receiving search head (install-token-meter.sh --metric-host <remote-sh>).
#
# Usage:
#   ./simulate-search-heads.sh --proxy http://<gpu-host>:8101 [--backend ollama] [--model NAME] \
#        [--search-heads 203.0.113.10,203.0.113.11 | --heads 3] [--requests 5] [--api-key <vllm-key>]
#
#   --search-heads <csv>  real SH identifiers (IPs/hostnames) used as the X-Splunk-Origin per call;
#                         e.g. the search head + a Splunk on the GPU box acting as a 2nd search head.
#   --heads <n>           OR just generate n synthetic heads (search-head-1..n). Ignored if --search-heads set.
#   --backend ollama  (default)  POST <proxy>/api/chat               (no key; e.g. proxy port 8101)
#   --backend vllm               POST <proxy>/v1/chat/completions    (Bearer --api-key; port 8100)

log()  { printf '[sim] %s\n' "$*"; }
die()  { printf '[sim] ERROR: %s\n' "$*" >&2; exit 1; }

PROXY=""; BACKEND="ollama"; MODEL=""; HEADS=3; REQUESTS=5; API_KEY=""; SEARCH_HEADS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy)         PROXY="$2"; shift 2;;
    --backend)       BACKEND="$2"; shift 2;;
    --model)         MODEL="$2"; shift 2;;
    --search-heads)  SEARCH_HEADS="$2"; shift 2;;
    --heads)         HEADS="$2"; shift 2;;
    --requests)      REQUESTS="$2"; shift 2;;
    --api-key)       API_KEY="$2"; shift 2;;
    -h|--help)       sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown argument: $1";;
  esac
done
[[ -n "${PROXY}" ]] || die "--proxy <url> is required (the GPU host's token-meter proxy)"
[[ "${HEADS}" =~ ^[0-9]+$ && "${REQUESTS}" =~ ^[0-9]+$ ]] || die "--heads/--requests must be integers"
PROXY="${PROXY%/}"

# Build the list of search heads (origins): an explicit --search-heads list, else n synthetic ones.
HEAD_LIST=()
if [[ -n "${SEARCH_HEADS}" ]]; then
  IFS=',' read -ra _raw <<< "${SEARCH_HEADS}"
  for h in "${_raw[@]}"; do h="$(echo "$h" | xargs)"; [[ -n "$h" ]] && HEAD_LIST+=("$h"); done
else
  for i in $(seq 1 "${HEADS}"); do HEAD_LIST+=("search-head-${i}"); done
fi
[[ ${#HEAD_LIST[@]} -gt 0 ]] || die "no search heads to simulate"

case "${BACKEND}" in
  ollama) URL="${PROXY}/api/chat";           MODEL="${MODEL:-granite-3.1-2b}";;
  vllm)   URL="${PROXY}/v1/chat/completions"; MODEL="${MODEL:-ibm-granite/granite-3.1-2b-instruct}";;
  *) die "--backend must be 'ollama' or 'vllm'";;
esac

PROMPTS=(
  "list the splunk indexes with the most events in the last hour"
  "write SPL to find failed logins by source ip"
  "summarize the top errors in index=app over the last 15 minutes"
  "which host has the highest cpu utilisation right now"
  "detect anomalies in web access logs and explain them"
  "generate a search for 5xx spikes grouped by service"
)

log "simulating ${#HEAD_LIST[@]} search head(s) [${HEAD_LIST[*]}] x ${REQUESTS} request(s) -> ${URL} (backend=${BACKEND}, model=${MODEL})"
sent=0; ok=0; idx=0
for origin in "${HEAD_LIST[@]}"; do
  idx=$((idx + 1)); user="analyst@${origin}"
  for j in $(seq 1 "${REQUESTS}"); do
    prompt="${PROMPTS[$(( (idx + j) % ${#PROMPTS[@]} ))]}"
    body="$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"stream":false}' "${MODEL}" "${prompt}")"
    hdr_auth=(); [[ "${BACKEND}" == "vllm" && -n "${API_KEY}" ]] && hdr_auth=(-H "Authorization: Bearer ${API_KEY}")
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 120 "${URL}" \
      -H "Content-Type: application/json" \
      -H "X-Splunk-Origin: ${origin}" -H "X-Splunk-User: ${user}" -H "X-Splunk-App: Splunk_ML_Toolkit" \
      "${hdr_auth[@]}" -d "${body}" 2>/dev/null || echo 000)"
    sent=$((sent + 1)); [[ "${code}" == 200 ]] && ok=$((ok + 1))
    log "  ${origin} req ${j}/${REQUESTS} -> HTTP ${code}"
  done
done

log "done: ${ok}/${sent} calls returned 200 (each metered call is one token_metrics event)"
log "On the RECEIVING search head, confirm all heads landed in the one index:"
log "  index=token_metrics earliest=-15m | stats count sum(total_tokens) as tokens by origin"
