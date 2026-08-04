#!/usr/bin/env bash
set -euo pipefail

# Bootstrap orchestrator for the search head (t3.medium): Splunk Enterprise with
# apps + license, configured to drive the AI containers running on the GPU host.
# No Docker/NVIDIA/Ollama/Milvus stages run here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

exec > >(tee -a /var/log/splunk-ai-bootstrap.log) 2>&1

log "Fetching secrets before staged bootstrap"
bash "${SCRIPT_DIR}/fetch-secrets.sh"

CHECKPOINT_DIR="${STATE_DIR}/bootstrap-checkpoints"
mkdir -p "${CHECKPOINT_DIR}"

if [[ "${RESET_BOOTSTRAP_CHECKPOINTS:-false}" == "true" ]]; then
  log "Resetting bootstrap checkpoints"
  rm -f "${CHECKPOINT_DIR}"/*.done 2>/dev/null || true
fi

# awscli/jq are needed by the Splunk stages; the search head has no 01-docker.sh
# to install them, so ensure them here.
log "Ensuring base packages on search head"
retry 5 10 dnf makecache
ensure_dnf_package jq
ensure_dnf_package awscli
ensure_dnf_package unzip

stages=(
  "06-splunk.sh"
  "07-license.sh"
  "08-apps.sh"
  "11-token-metrics.sh"
  "09-configure-searchhead.sh"
  "datagen/populate-splunk-data.sh"
)

for stage in "${stages[@]}"; do
  checkpoint_file="${CHECKPOINT_DIR}/${stage//\//_}.done"
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

log "Search head bootstrap completed successfully"
