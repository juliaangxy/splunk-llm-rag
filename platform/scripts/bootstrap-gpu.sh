#!/usr/bin/env bash
set -euo pipefail

# Bootstrap orchestrator for the GPU host (g4dn.4xlarge): Splunk Enterprise plus
# the full Dockerized AI stack (Ollama + both LLMs, Milvus/MinIO/etcd, DSDL/MLTK).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

exec > >(tee -a /var/log/splunk-ai-bootstrap.log) 2>&1

# Secrets are fetched every boot (not checkpointed) so rotation takes effect.
log "Fetching secrets before staged bootstrap"
bash "${SCRIPT_DIR}/fetch-secrets.sh"

CHECKPOINT_DIR="${STATE_DIR}/bootstrap-checkpoints"
mkdir -p "${CHECKPOINT_DIR}"

if [[ "${RESET_BOOTSTRAP_CHECKPOINTS:-false}" == "true" ]]; then
  log "Resetting bootstrap checkpoints"
  rm -f "${CHECKPOINT_DIR}"/*.done 2>/dev/null || true
fi

stages=(
  "01-docker.sh"
  "02-nvidia.sh"
  "03-ollama.sh"
  "04-model.sh"
  "05-milvus.sh"
  "06-splunk.sh"
  "07-license.sh"
  "08-apps.sh"
  "11-token-metrics.sh"
  "09-configure-gpu.sh"
  "12-vllm.sh"
  "10-snapshot.sh"
)

for stage in "${stages[@]}"; do
  checkpoint_file="${CHECKPOINT_DIR}/${stage}.done"
  step="${SCRIPT_DIR}/${stage}"

  if [[ -f "${checkpoint_file}" ]]; then
    log "Skipping stage ${stage}; checkpoint exists"
    continue
  fi

  if [[ ! -f "${step}" ]]; then
    error "Missing stage script: ${step}"
    exit 1
  fi

  log "Starting stage ${stage}"
  bash "${step}"
  touch "${checkpoint_file}"
  log "Completed stage ${stage}"
done

log "GPU host bootstrap completed successfully"
