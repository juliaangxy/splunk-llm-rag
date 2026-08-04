#!/usr/bin/env bash
set -euo pipefail

# Search-head post-install configuration: point Splunk's DSDL / MLTK container
# integration at the AI containers running on the remote GPU host. No local
# Docker/Ollama/Milvus runs here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"

# The GPU host's private IP is injected by CloudFormation user-data.
GPU_HOST="${GPU_HOST:-}"
DOCKER_PORT="${DOCKER_PORT:-2375}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
MILVUS_PORT="${MILVUS_PORT:-19530}"

# Endpoints derived from the GPU host unless explicitly overridden.
if [[ -n "${GPU_HOST}" ]]; then
  DSDL_DOCKER_HOST="${DSDL_DOCKER_HOST:-tcp://${GPU_HOST}:${DOCKER_PORT}}"
  DSDL_ENDPOINT_URL="${DSDL_ENDPOINT_URL:-https://${GPU_HOST}:${DOCKER_PORT}}"
  DSDL_EXTERNAL_URL="${DSDL_EXTERNAL_URL:-https://${GPU_HOST}:${DOCKER_PORT}}"
  MLTK_CONTAINER_EXTERNAL_HOST="${MLTK_CONTAINER_EXTERNAL_HOST:-${GPU_HOST}}"
else
  warn "GPU_HOST is not set; falling back to any provided DSDL_* endpoint values"
  DSDL_DOCKER_HOST="${DSDL_DOCKER_HOST:-tcp://127.0.0.1:${DOCKER_PORT}}"
  DSDL_ENDPOINT_URL="${DSDL_ENDPOINT_URL:-https://127.0.0.1:${DOCKER_PORT}}"
  DSDL_EXTERNAL_URL="${DSDL_EXTERNAL_URL:-https://127.0.0.1:${DOCKER_PORT}}"
  MLTK_CONTAINER_EXTERNAL_HOST="${MLTK_CONTAINER_EXTERNAL_HOST:-127.0.0.1}"
fi

DSDL_DOCKER_NETWORK="${DSDL_DOCKER_NETWORK:-dsenv-network}"
# The search head connects over the VPC; allow the whole VPC CIDR by default.
DOCKER_REMOTE_CIDR="${DOCKER_REMOTE_CIDR:-${VPC_CIDR:-0.0.0.0/0}}"
RAG_MODEL_NAME="${RAG_MODEL_NAME:-llama3.1:8b}"
CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON:-}"
SPLUNK_LLM_RAG_IMAGE="${SPLUNK_LLM_RAG_IMAGE:-}"
SPLUNK_LLM_RAG_HOST_PORT="${SPLUNK_LLM_RAG_HOST_PORT:-5001}"

export SPLUNK_HOME DSDL_DOCKER_HOST DSDL_ENDPOINT_URL DSDL_EXTERNAL_URL \
  DSDL_DOCKER_NETWORK DOCKER_REMOTE_CIDR RAG_MODEL_NAME MLTK_CONTAINER_EXTERNAL_HOST

configure_mltk_container_profiles() {
  local mltk_local_dir="${SPLUNK_HOME}/etc/apps/mltk-container/local"
  local containers_conf="${mltk_local_dir}/containers.conf"

  mkdir -p "${mltk_local_dir}"

  if [[ -n "${CONTAINER_IMAGE_PROFILES_JSON}" ]]; then
    require_cmd python3
    log "Generating containers.conf from CONTAINER_IMAGE_PROFILES_JSON (remote host ${MLTK_CONTAINER_EXTERNAL_HOST})"
    CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" \
    ECR_REGISTRY_URI="${ECR_REGISTRY_URI:-}" \
    ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-}" \
    DSDL_DOCKER_HOST="${DSDL_DOCKER_HOST}" \
    CONTAINERS_CONF_PATH="${containers_conf}" \
    python3 "${SCRIPT_DIR}/dsdl/generate_containers_conf.py"
  else
    cat > "${containers_conf}" <<EOF
[default]
cluster = docker

[__dev__]
cluster = docker
id =
image = ${SPLUNK_LLM_RAG_IMAGE:-unknown}
mode = DEV
api_url_external = https://${MLTK_CONTAINER_EXTERNAL_HOST}:${SPLUNK_LLM_RAG_HOST_PORT}
runtime = None
api_url = https://${MLTK_CONTAINER_EXTERNAL_HOST}:${SPLUNK_LLM_RAG_HOST_PORT}
EOF
  fi

  if id -u splunk >/dev/null 2>&1; then
    chown splunk:splunk "${containers_conf}"
  fi
  chmod 0644 "${containers_conf}"
  log "Configured mltk-container profiles in ${containers_conf}"
}

configure_mltk_container_images() {
  local mltk_local_dir="${SPLUNK_HOME}/etc/apps/mltk-container/local"
  local images_conf="${mltk_local_dir}/images.conf"

  mkdir -p "${mltk_local_dir}"

  if is_airgapped && [[ -n "${ECR_REGISTRY_URI:-}" && -n "${ECR_REPOSITORY_NAME:-}" ]]; then
    require_cmd python3
    log "Airgapped: writing local/images.conf for all default DSDL images pointed at ECR"
    ECR_REGISTRY_URI="${ECR_REGISTRY_URI}" \
    ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME}" \
    IMAGES_CONF_PATH="${images_conf}" \
    python3 "${SCRIPT_DIR}/dsdl/generate_default_images_conf.py"
  elif [[ -n "${CONTAINER_IMAGE_PROFILES_JSON}" ]]; then
    require_cmd python3
    log "Generating images.conf from CONTAINER_IMAGE_PROFILES_JSON"
    CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" \
    ECR_REGISTRY_URI="${ECR_REGISTRY_URI:-}" \
    ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-}" \
    IMAGES_CONF_PATH="${images_conf}" \
    python3 "${SCRIPT_DIR}/dsdl/generate_images_conf.py"
  else
    cat > "${images_conf}" <<EOF
[default]
cluster = docker
EOF
  fi

  if id -u splunk >/dev/null 2>&1; then
    chown splunk:splunk "${images_conf}"
  fi
  chmod 0644 "${images_conf}"
  log "Configured mltk-container images in ${images_conf}"
}

configure_dsdl_endpoint() {
  local dsdl_local_dir="${SPLUNK_HOME}/etc/apps/dsdl/local"
  mkdir -p "${dsdl_local_dir}"

  cat > "${dsdl_local_dir}/docker.conf" <<EOF
[docker]
endpoint = ${DSDL_DOCKER_HOST}
docker_host = ${DSDL_DOCKER_HOST}
endpoint_url = ${DSDL_ENDPOINT_URL}
external_url = ${DSDL_EXTERNAL_URL}
docker_network = ${DSDL_DOCKER_NETWORK}
allowed_cidr = ${DOCKER_REMOTE_CIDR}
EOF

  if id -u splunk >/dev/null 2>&1; then
    chown -R splunk:splunk "${dsdl_local_dir}"
  fi
  log "Configured DSDL remote endpoint in ${dsdl_local_dir}/docker.conf -> ${DSDL_DOCKER_HOST}"
}

run_post_install_ansible_config() {
  local playbook_path="${SCRIPT_DIR}/configure-splunk-apps.yml"

  if [[ ! -f "${playbook_path}" ]]; then
    warn "Ansible playbook not found at ${playbook_path}; skipping app configuration"
    return 0
  fi

  if ! command -v ansible-playbook >/dev/null 2>&1; then
    log "Installing ansible-core for post-install app configuration"
    ensure_dnf_package ansible-core
  fi

  log "Running post-install app configuration playbook"
  ansible-playbook -i 'localhost,' -c local -b "${playbook_path}"
}

verify_remote_services() {
  if [[ -z "${GPU_HOST}" ]]; then
    warn "GPU_HOST unset; skipping remote service reachability checks"
    return 0
  fi
  log "Verifying reachability of remote AI services on ${GPU_HOST}"
  wait_for_port "${GPU_HOST}" "${DOCKER_PORT}" 300
  wait_for_port "${GPU_HOST}" "${OLLAMA_PORT}" 300
  wait_for_port "${GPU_HOST}" "${MILVUS_PORT}" 300 || warn "Milvus port ${MILVUS_PORT} on ${GPU_HOST} not reachable yet"
}

log "Applying search-head post-install configuration"
verify_remote_services
configure_mltk_container_profiles
configure_mltk_container_images
configure_dsdl_endpoint
# Wire the vLLM (OpenAI) + Ollama LLM endpoints. When token metering is enabled, start
# LOCAL proxies that forward to the GPU host's models but ship metrics to THIS instance's
# HEC, and point AITK at them so search-head-initiated calls are counted here. Otherwise
# point AITK straight at the GPU host's models.
if [[ "${DEPLOY_TOKEN_METER_PROXY:-false}" == "true" ]]; then
  log "DEPLOY_TOKEN_METER_PROXY=true; starting local token-metering proxies (upstream ${GPU_HOST})"
  # Generate the HEC destination file first so this instance's proxy ships metrics to the
  # configured target (default: the search head itself, i.e. its own local HEC).
  TOKEN_METER_DEFAULT_ROLE="${TOKEN_METER_DEFAULT_ROLE:-search-head}" \
    bash "${SCRIPT_DIR}/token-meter/configure-token-meter-routes.sh" || warn "token-meter destination generation failed (non-fatal); using single-HEC default"
  UPSTREAM_HOST="${GPU_HOST}" bash "${SCRIPT_DIR}/token-meter/start-token-meter-proxies.sh" || warn "token-meter proxy start failed (non-fatal)"
  bash "${SCRIPT_DIR}/configure-splunk-llm.sh" --mode proxy || warn "configure-splunk-llm.sh (proxy) failed"
else
  GPU_HOST="${GPU_HOST}" bash "${SCRIPT_DIR}/configure-splunk-llm.sh" --mode direct || warn "configure-splunk-llm.sh (direct) failed"
fi
run_post_install_ansible_config

if [[ -x "${SPLUNK_HOME}/bin/splunk" ]]; then
  require_env SPLUNK_ADMIN_PASSWORD
  ensure_splunk_restart_required_change_health_non_interactive \
    "Splunk is running after remote-host config updates; attempting reload before any full restart" \
    "Splunk is not running; issuing start to apply configuration"
fi

bash "${SCRIPT_DIR}/configure-admin-roles.sh" || warn "admin role configuration failed (non-fatal)"

log "Search-head post-install configuration completed"
