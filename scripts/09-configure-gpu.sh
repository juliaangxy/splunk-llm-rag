#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
DOCKER_REMOTE_CIDR="${DOCKER_REMOTE_CIDR:-127.0.0.1/32}"
DOCKER_PORT="2375"
DSDL_DOCKER_NETWORK="${DSDL_DOCKER_NETWORK:-dsenv-network}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"
AI_ARTIFACTS_BUCKET="${AI_ARTIFACTS_BUCKET:-}"
DSDL_EMBEDDING_MODEL_S3_PREFIX="${DSDL_EMBEDDING_MODEL_S3_PREFIX:-models/huggingface/sentence-transformers/all-MiniLM-L6-v2/}"
DSDL_EMBEDDING_MODEL_DIR="${DSDL_EMBEDDING_MODEL_DIR:-/opt/splunk-ai/models/all-MiniLM-L6-v2}"
DSDL_CPU_INFERENCE_IMAGE="${DSDL_CPU_INFERENCE_IMAGE:-}"
DEFAULT_DSDL_CPU_INFERENCE_IMAGE="splunk/dsdl-images:deep-learning-backbone-cpu"
DSDL_CPU_INFERENCE_CONTAINER_NAME="${DSDL_CPU_INFERENCE_CONTAINER_NAME:-dsdl-cpu-inference}"
DSDL_CPU_INFERENCE_PORT="${DSDL_CPU_INFERENCE_PORT:-5002}"
DSDL_CPU_INFERENCE_RUN_AS_ROOT="${DSDL_CPU_INFERENCE_RUN_AS_ROOT:-auto}"
DSDL_INTEGRATION_SCRIPT_SOURCE="${DSDL_INTEGRATION_SCRIPT_SOURCE:-/opt/splunk-ai/scripts/minilm_embedding.py}"
DSDL_INTEGRATION_SCRIPT_BASENAME="${DSDL_INTEGRATION_SCRIPT_BASENAME:-minilm_embedding.py}"
DSDL_INTEGRATION_SCRIPT_HOST_DIR="${DSDL_INTEGRATION_SCRIPT_HOST_DIR:-/opt/splunk-ai/dsdl-notebooks/custom}"
DSDL_INTEGRATION_SCRIPT_CONTAINER_DIR="${DSDL_INTEGRATION_SCRIPT_CONTAINER_DIR:-/srv/app/notebooks/custom}"
SPLUNK_DSDL_INTEGRATION_DIR="${SPLUNK_DSDL_INTEGRATION_DIR:-${SPLUNK_HOME}/etc/apps/dsdl/local/blueprints}"
VERIFY_MILVUS_PORT="${VERIFY_MILVUS_PORT:-auto}"
MILVUS_COMPOSE_FILE="${MILVUS_COMPOSE_FILE:-/opt/splunk-ai/milvus/docker-compose.yaml}"

SPLUNK_MLTK_GPU_IMAGE="${SPLUNK_MLTK_GPU_IMAGE:-}"
SPLUNK_LLM_RAG_IMAGE="${SPLUNK_LLM_RAG_IMAGE:-}"
SPLUNK_LLM_RAG_HOST_PORT="${SPLUNK_LLM_RAG_HOST_PORT:-5001}"
SPLUNK_MLTK_GPU_HOST_PORT="${SPLUNK_MLTK_GPU_HOST_PORT:-5003}"
MLTK_CONTAINER_EXTERNAL_HOST="${MLTK_CONTAINER_EXTERNAL_HOST:-}"
CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON:-}"
# When false (default), do NOT pull/start the DSDL/MLTK containers (gpu, llm_rag, cpu)
# during deployment. They caused heavy cloud-init image pulls; the user starts the
# relevant container manually per workload. images.conf/containers.conf and the ECR
# credential helper are still configured so manual starts work.
AUTO_PULL_DSDL_CONTAINERS="${AUTO_PULL_DSDL_CONTAINERS:-false}"

container_profiles_json_is_set() {
	[[ -n "${CONTAINER_IMAGE_PROFILES_JSON}" ]]
}

apply_container_profiles_json_overrides() {
	local assignments

	if ! container_profiles_json_is_set; then
		return 0
	fi

	require_cmd python3
	assignments="$(CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" python3 - <<'PY'
import json
import os
import shlex
import sys

profiles = json.loads(os.environ['CONTAINER_IMAGE_PROFILES_JSON'])
if not isinstance(profiles, list):
	raise SystemExit('CONTAINER_IMAGE_PROFILES_JSON must be a JSON array')

role_map = {
	'llm_rag': ('SPLUNK_LLM_RAG_IMAGE', 'SPLUNK_LLM_RAG_HOST_PORT'),
	'gpu_container': ('SPLUNK_MLTK_GPU_IMAGE', 'SPLUNK_MLTK_GPU_HOST_PORT'),
	'cpu_container': ('DSDL_CPU_INFERENCE_IMAGE', 'DSDL_CPU_INFERENCE_PORT'),
}

assigned = {}
for profile in profiles:
	if not isinstance(profile, dict):
		continue
	role = str(profile.get('role', '') or '').strip()
	if role not in role_map or role in assigned:
		continue
	image = str(profile.get('image') or profile.get('source_image') or '').strip()
	host_port = profile.get('host_port')
	image_var, port_var = role_map[role]
	assigned[role] = True
	print(f"{image_var}={shlex.quote(image)}")
	if host_port not in (None, ''):
		print(f"{port_var}={shlex.quote(str(host_port))}")
PY
)"

	if [[ -n "${assignments}" ]]; then
		while IFS= read -r assignment; do
			[[ -n "${assignment}" ]] || continue
			eval "${assignment}"
		done <<< "${assignments}"
	fi
}

resolve_dsdl_cpu_inference_image() {
	if [[ -n "${DSDL_CPU_INFERENCE_IMAGE}" ]]; then
		return 0
	fi

	if [[ -n "${SPLUNK_MLTK_GPU_IMAGE}" ]]; then
		local source_repo source_tag version candidate
		source_repo="${SPLUNK_MLTK_GPU_IMAGE%:*}"
		source_tag="${SPLUNK_MLTK_GPU_IMAGE##*:}"

		if [[ "${source_tag}" =~ ^mltk-container-golden-gpu-(.+)$ ]]; then
			version="${BASH_REMATCH[1]}"
		else
			version="5.2.3"
		fi

		candidate="${source_repo}:mltk-container-golden-cpu-${version}"
		if [[ "${source_repo}" == *.dkr.ecr.*.amazonaws.com/* ]]; then
			DSDL_CPU_INFERENCE_IMAGE="${candidate}"
			log "Derived DSDL CPU inference image from SPLUNK_MLTK_GPU_IMAGE: ${DSDL_CPU_INFERENCE_IMAGE}"
			return 0
		fi
	fi

	DSDL_CPU_INFERENCE_IMAGE="${DEFAULT_DSDL_CPU_INFERENCE_IMAGE}"
	warn "DSDL_CPU_INFERENCE_IMAGE is unset; falling back to default image ${DSDL_CPU_INFERENCE_IMAGE}"
}

should_run_dsdl_cpu_as_root() {
	case "${DSDL_CPU_INFERENCE_RUN_AS_ROOT}" in
		true)
			return 0
			;;
		false)
			return 1
			;;
		auto)
			if [[ "${DSDL_CPU_INFERENCE_IMAGE}" == *":mltk-container-golden-cpu-"* || "${DSDL_CPU_INFERENCE_IMAGE}" == *"/mltk-container-golden-cpu:"* ]]; then
				return 0
			fi
			return 1
			;;
		*)
			warn "Unrecognized DSDL_CPU_INFERENCE_RUN_AS_ROOT=${DSDL_CPU_INFERENCE_RUN_AS_ROOT}; using auto"
			if [[ "${DSDL_CPU_INFERENCE_IMAGE}" == *":mltk-container-golden-cpu-"* || "${DSDL_CPU_INFERENCE_IMAGE}" == *"/mltk-container-golden-cpu:"* ]]; then
				return 0
			fi
			return 1
			;;
	esac
}

declare -a OPTIONAL_IMAGE_URIS=()

add_optional_image_uri() {
	local image_uri="${1:-}"
	local existing

	image_uri="$(echo "${image_uri}" | xargs)"
	if [[ -z "${image_uri}" ]]; then
		return 0
	fi

	for existing in "${OPTIONAL_IMAGE_URIS[@]}"; do
		if [[ "${existing}" == "${image_uri}" ]]; then
			return 0
		fi
	done

	OPTIONAL_IMAGE_URIS+=("${image_uri}")
}

collect_optional_image_uris() {
	local json_images var_name

	if container_profiles_json_is_set; then
		require_cmd python3
		json_images="$(CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" python3 - <<'PY'
import json
import os

profiles = json.loads(os.environ['CONTAINER_IMAGE_PROFILES_JSON'])
for profile in profiles:
    if not isinstance(profile, dict):
        continue
    image = str(profile.get('image') or profile.get('source_image') or '').strip()
    if image:
        print(image)
PY
)"
		while IFS= read -r image_uri; do
			[[ -n "${image_uri}" ]] || continue
			add_optional_image_uri "${image_uri}"
		done <<< "${json_images}"
	fi

	for var_name in $(compgen -v SPLUNK_); do
		if [[ "${var_name}" == SPLUNK_*_IMAGE ]]; then
			add_optional_image_uri "${!var_name:-}"
		fi
	done

	if [[ "${DSDL_CPU_INFERENCE_IMAGE}" == *.dkr.ecr.*.amazonaws.com/* ]]; then
		add_optional_image_uri "${DSDL_CPU_INFERENCE_IMAGE}"
	fi

	log "Detected ${#OPTIONAL_IMAGE_URIS[@]} configured optional image URI(s)"
}

normalize_s3_prefix() {
	local prefix="${1}"
	if [[ -n "${prefix}" && "${prefix}" != */ ]]; then
		prefix="${prefix}/"
	fi
	echo "${prefix}"
}

ecr_registry_from_image_uri() {
	local image_uri="${1}"
	local registry

	if [[ "${image_uri}" != */* ]]; then
		return 1
	fi

	registry="${image_uri%%/*}"
	if [[ "${registry}" == *.dkr.ecr.*.amazonaws.com ]]; then
		echo "${registry}"
		return 0
	fi

	return 1
}

ecr_region_from_registry() {
	local registry="${1}"

	if [[ "${registry}" =~ ^[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]]; then
		echo "${BASH_REMATCH[1]}"
		return 0
	fi

	return 1
}

ensure_ecr_credential_helper() {
	if command -v docker-credential-ecr-login >/dev/null 2>&1; then
		return 0
	fi

	log "Installing amazon-ecr-credential-helper for secure ECR pulls"
	if dnf install -y amazon-ecr-credential-helper >/dev/null 2>&1; then
		return 0
	fi

	warn "Could not install amazon-ecr-credential-helper; falling back to docker login"
	return 1
}

configure_ecr_credential_helper() {
	local config_dir="/root/.docker"
	local config_file="${config_dir}/config.json"
	local first=1
	local registry

	mkdir -p "${config_dir}"

	{
		echo "{"
		echo "  \"credHelpers\": {"
		for registry in "$@"; do
			if [[ "${first}" -eq 0 ]]; then
				echo ","
			fi
			printf '    "%s": "ecr-login"' "${registry}"
			first=0
		done
		echo
		echo "  }"
		echo "}"
	} > "${config_file}"

	chmod 600 "${config_file}"
	log "Configured Docker ECR credential helper in ${config_file}"
}

login_to_required_ecr_registries() {
	local image_uri registry region existing already_logged helper_enabled
	local -a logged_registries=()

	if [[ "${#OPTIONAL_IMAGE_URIS[@]}" -eq 0 ]]; then
		return 0
	fi

	require_cmd aws
	helper_enabled=0
	if ensure_ecr_credential_helper; then
		helper_enabled=1
	fi

	for image_uri in "${OPTIONAL_IMAGE_URIS[@]}"; do
		registry="$(ecr_registry_from_image_uri "${image_uri}" || true)"
		if [[ -z "${registry}" ]]; then
			continue
		fi

		already_logged=0
		for existing in "${logged_registries[@]}"; do
			if [[ "${existing}" == "${registry}" ]]; then
				already_logged=1
				break
			fi
		done

		if [[ "${already_logged}" -eq 1 ]]; then
			continue
		fi

		if [[ "${helper_enabled}" -eq 1 ]]; then
			logged_registries+=("${registry}")
			continue
		fi

		region="$(ecr_region_from_registry "${registry}" || true)"
		if [[ -z "${region}" ]]; then
			warn "Could not infer ECR region from registry ${registry}; skipping docker login"
			continue
		fi

		log "Logging in to ECR registry ${registry} for optional image pulls"
		if ! aws ecr get-login-password --region "${region}" | docker login --username AWS --password-stdin "${registry}" >/dev/null; then
			warn "Failed to authenticate to ${registry}; docker pull may fail for related images"
			continue
		fi

		logged_registries+=("${registry}")
		log "Authenticated to ${registry}"
	done

	if [[ "${helper_enabled}" -eq 1 && "${#logged_registries[@]}" -gt 0 ]]; then
		configure_ecr_credential_helper "${logged_registries[@]}"
	fi
}

pull_optional_images() {
	local image_uri

	for image_uri in "${OPTIONAL_IMAGE_URIS[@]}"; do
		log "Pulling optional image ${image_uri}"
		if ! docker pull "${image_uri}" >/dev/null; then
			warn "Failed to pull optional image ${image_uri}; container start may fail"
		fi
	done
}

resolve_mltk_container_external_host() {
	if [[ -n "${MLTK_CONTAINER_EXTERNAL_HOST}" ]]; then
		return 0
	fi

	# Extract host from DSDL_DOCKER_HOST (e.g., tcp://10.0.0.1:2375 -> 10.0.0.1)
	MLTK_CONTAINER_EXTERNAL_HOST="$(extract_docker_host_from_uri "${DSDL_DOCKER_HOST:-tcp://127.0.0.1:2375}")"
	log "Resolved MLTK_CONTAINER_EXTERNAL_HOST from DSDL_DOCKER_HOST: ${MLTK_CONTAINER_EXTERNAL_HOST}"
}

stage_minilm_integration_script() {
	local host_target splunk_target

	mkdir -p "${DSDL_INTEGRATION_SCRIPT_HOST_DIR}"
	mkdir -p "${SPLUNK_DSDL_INTEGRATION_DIR}"

	if [[ ! -f "${DSDL_INTEGRATION_SCRIPT_SOURCE}" ]]; then
		warn "Integration script ${DSDL_INTEGRATION_SCRIPT_SOURCE} not found; skipping DSDL blueprint staging"
		return 0
	fi

	host_target="${DSDL_INTEGRATION_SCRIPT_HOST_DIR}/${DSDL_INTEGRATION_SCRIPT_BASENAME}"
	splunk_target="${SPLUNK_DSDL_INTEGRATION_DIR}/${DSDL_INTEGRATION_SCRIPT_BASENAME}"

	cp "${DSDL_INTEGRATION_SCRIPT_SOURCE}" "${host_target}"
	cp "${DSDL_INTEGRATION_SCRIPT_SOURCE}" "${splunk_target}"
	chmod 0644 "${host_target}" "${splunk_target}"

	if id -u splunk >/dev/null 2>&1; then
		chown splunk:splunk "${splunk_target}"
	fi

	log "Staged DSDL integration script in Splunk at ${splunk_target}"
	log "Mounted DSDL integration script source at ${DSDL_INTEGRATION_SCRIPT_CONTAINER_DIR}/${DSDL_INTEGRATION_SCRIPT_BASENAME}"
}

deploy_dsdl_cpu_inference_container() {
	local model_prefix s3_uri

	if [[ -z "${AI_ARTIFACTS_BUCKET}" ]]; then
		log "AI_ARTIFACTS_BUCKET is empty; skipping DSDL CPU embedding container setup"
		return 0
	fi

	require_cmd aws

	model_prefix="$(normalize_s3_prefix "${DSDL_EMBEDDING_MODEL_S3_PREFIX}")"
	s3_uri="s3://${AI_ARTIFACTS_BUCKET}/${model_prefix}"

	mkdir -p "${DSDL_EMBEDDING_MODEL_DIR}"
	log "Syncing embedding model artifacts from ${s3_uri}"
	if ! aws s3 sync "${s3_uri}" "${DSDL_EMBEDDING_MODEL_DIR}" --only-show-errors; then
		warn "Could not sync embedding model artifacts from ${s3_uri}; skipping DSDL CPU embedding container"
		return 0
	fi

	if [[ -z "$(find "${DSDL_EMBEDDING_MODEL_DIR}" -mindepth 1 -print -quit)" ]]; then
		warn "Embedding model directory ${DSDL_EMBEDDING_MODEL_DIR} is empty after sync; skipping DSDL CPU embedding container"
		return 0
	fi

	if [[ "${AUTO_PULL_DSDL_CONTAINERS}" != "true" ]]; then
		log "Skipping DSDL CPU inference image pull (AUTO_PULL_DSDL_CONTAINERS=false); embedding model staged for manual container start"
		return 0
	fi

	if ! docker image inspect "${DSDL_CPU_INFERENCE_IMAGE}" >/dev/null 2>&1; then
		log "Pulling DSDL CPU inference image ${DSDL_CPU_INFERENCE_IMAGE}"
		if ! docker pull "${DSDL_CPU_INFERENCE_IMAGE}" >/dev/null 2>&1; then
			warn "Could not pull DSDL CPU inference image ${DSDL_CPU_INFERENCE_IMAGE}; skipping DSDL CPU embedding container"
			return 0
		fi
	fi

	log "Prepared DSDL CPU embedding assets and image ${DSDL_CPU_INFERENCE_IMAGE}; startup is managed by mltk-container containers.conf"
}

run_post_install_ansible_config() {
	local playbook_path="/opt/splunk-ai/scripts/configure-splunk-apps.yml"

	if [[ ! -f "${playbook_path}" ]]; then
		warn "Post-install Ansible playbook not found at ${playbook_path}; skipping app configuration"
		return 0
	fi

	if ! command -v ansible-playbook >/dev/null 2>&1; then
		log "Installing ansible-core for post-install app configuration"
		ensure_dnf_package ansible-core
	fi

	log "Running post-install app configuration playbook: ${playbook_path}"
	ansible-playbook -i 'localhost,' -c local -b "${playbook_path}"
}

configure_docker_remote_api() {
	if [[ -f /etc/systemd/system/docker.service.d/override.conf && -f /etc/docker/daemon.json ]]; then
		log "Docker daemon remote API configuration already present; skipping Docker restart"
		return 0
	fi

	mkdir -p /etc/systemd/system/docker.service.d

	cat > /etc/systemd/system/docker.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --host=fd:// --host=tcp://0.0.0.0:${DOCKER_PORT}
EOF

	mkdir -p /etc/docker
	cat > /etc/docker/daemon.json <<EOF
{
	"default-runtime": "nvidia",
	"runtimes": {
		"nvidia": {
			"path": "nvidia-container-runtime",
			"runtimeArgs": []
		}
	},
	"live-restore": true,
	"iptables": true
}
EOF

	systemctl daemon-reload
	systemctl restart docker
}

configure_mltk_container_profiles() {
	local mltk_local_dir="${SPLUNK_HOME}/etc/apps/mltk-container/local"
	local containers_conf="${mltk_local_dir}/containers.conf"

	resolve_mltk_container_external_host
	mkdir -p "${mltk_local_dir}"

	if container_profiles_json_is_set; then
		require_cmd python3
		log "Generating containers.conf from CONTAINER_IMAGE_PROFILES_JSON"
		CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" \
		ECR_REGISTRY_URI="${ECR_REGISTRY_URI:-}" \
		ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-}" \
		DSDL_DOCKER_HOST="${DSDL_DOCKER_HOST:-tcp://127.0.0.1:2375}" \
		CONTAINERS_CONF_PATH="${containers_conf}" \
		python3 "${SCRIPT_DIR}/generate_containers_conf.py"
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
	log "Configured mltk-container profiles in ${containers_conf} using host ${MLTK_CONTAINER_EXTERNAL_HOST}"
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
		python3 "${SCRIPT_DIR}/generate_default_images_conf.py"
	elif container_profiles_json_is_set; then
		require_cmd python3
		log "Generating images.conf from CONTAINER_IMAGE_PROFILES_JSON"
		CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" \
		ECR_REGISTRY_URI="${ECR_REGISTRY_URI:-}" \
		ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-}" \
		IMAGES_CONF_PATH="${images_conf}" \
		python3 "${SCRIPT_DIR}/generate_images_conf.py"
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

ensure_dsdl_docker_network() {
	if ! docker network inspect "${DSDL_DOCKER_NETWORK}" >/dev/null 2>&1; then
		log "Creating Docker network ${DSDL_DOCKER_NETWORK} for DSDL containers"
		docker network create "${DSDL_DOCKER_NETWORK}" >/dev/null
	fi
}

configure_dsdl_endpoint() {
	local dsdl_local_dir="${SPLUNK_HOME}/etc/apps/dsdl/local"
	mkdir -p "${dsdl_local_dir}"

	cat > "${dsdl_local_dir}/docker.conf" <<EOF
[docker]
endpoint = tcp://127.0.0.1:${DOCKER_PORT}
docker_host = ${DSDL_DOCKER_HOST}
endpoint_url = ${DSDL_ENDPOINT_URL}
external_url = ${DSDL_EXTERNAL_URL}
docker_network = ${DSDL_DOCKER_NETWORK}
allowed_cidr = ${DOCKER_REMOTE_CIDR}
EOF
}

reconcile_milvus_stack() {
	local compose

	if [[ ! -f "${MILVUS_COMPOSE_FILE}" ]]; then
		return 0
	fi

	compose="$(compose_cmd)"
	log "Reconciling Milvus stack after Docker restart using ${MILVUS_COMPOSE_FILE}"
	if ! ${compose} -f "${MILVUS_COMPOSE_FILE}" up -d >/dev/null; then
		warn "Failed to reconcile Milvus stack from ${MILVUS_COMPOSE_FILE}; Milvus readiness checks may fail"
	fi
}

connect_milvus_to_dsdl_network() {
	local container_name network_name

	# Try to find and connect milvus-standalone or milvus container to DSDL network
	for container_name in milvus-standalone milvus; do
		if docker ps -a --format '{{.Names}}' | grep -Eq "^${container_name}$"; then
			network_name="${DSDL_DOCKER_NETWORK}"
			
			# Check if container is already on the network
			if docker inspect "${container_name}" --format='{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q "${network_name}"; then
				log "Milvus container ${container_name} is already connected to ${network_name}"
				return 0
			fi
			
			# Connect container to DSDL network
			log "Connecting Milvus container ${container_name} to ${network_name}"
			if docker network connect "${network_name}" "${container_name}" 2>/dev/null; then
				log "Successfully connected Milvus to DSDL network"
				return 0
			else
				warn "Failed to connect Milvus container ${container_name} to ${network_name}"
				return 1
			fi
		fi
	done
	
	log "No Milvus container found; skipping network connection"
	return 0
}

should_verify_milvus_port() {
	case "${VERIFY_MILVUS_PORT}" in
		true)
			return 0
			;;
		false)
			return 1
			;;
		auto)
			if docker ps -a --format '{{.Names}}' | grep -Eq '^(milvus-standalone|milvus)$'; then
				return 0
			fi
			return 1
			;;
		*)
			warn "Unrecognized VERIFY_MILVUS_PORT=${VERIFY_MILVUS_PORT}; using auto"
			if docker ps -a --format '{{.Names}}' | grep -Eq '^(milvus-standalone|milvus)$'; then
				return 0
			fi
			return 1
			;;
	esac
}

verify_stack() {
	log "Verifying required local services after configuration"
	nvidia-smi >/dev/null
	docker info >/dev/null
	wait_for_port 127.0.0.1 11434 180
	if should_verify_milvus_port; then
		wait_for_port 127.0.0.1 19530 180
	else
		log "Skipping Milvus port verification on 127.0.0.1:19530"
	fi
	wait_for_port 127.0.0.1 "${DOCKER_PORT}" 120
}

log "Applying post-install configuration"
apply_container_profiles_json_overrides
resolve_dsdl_cpu_inference_image
configure_docker_remote_api
ensure_dsdl_docker_network
reconcile_milvus_stack
connect_milvus_to_dsdl_network
collect_optional_image_uris
login_to_required_ecr_registries
if [[ "${AUTO_PULL_DSDL_CONTAINERS}" == "true" ]]; then
	pull_optional_images
else
	log "Skipping pull/startup of the DSDL containers (gpu, llm_rag, cpu) during deployment (AUTO_PULL_DSDL_CONTAINERS=false); ECR credential helper is configured so they can be started manually per workload"
fi
stage_minilm_integration_script
deploy_dsdl_cpu_inference_container
configure_mltk_container_profiles
configure_mltk_container_images
configure_dsdl_endpoint
# Register the vLLM (OpenAI) + Ollama LLM endpoints. Default DIRECT-to-model so models
# work without the proxy; switch to metered proxy later with configure-splunk-llm.sh --mode proxy.
GPU_HOST="${GPU_HOST:-127.0.0.1}" bash "${SCRIPT_DIR}/configure-splunk-llm.sh" --mode direct || warn "configure-splunk-llm.sh failed"
run_post_install_ansible_config

# Ensure all long-running containers restart automatically.
for container_id in $(docker ps -q); do
	docker update --restart unless-stopped "${container_id}" >/dev/null
done

verify_stack

if [[ -x "${SPLUNK_HOME}/bin/splunk" ]]; then
	require_env SPLUNK_ADMIN_PASSWORD
	ensure_splunk_restart_required_change_health_non_interactive \
		"Splunk appears to be running after direct local .conf updates; attempting lightweight reload before any full restart" \
		"Splunk is not running; issuing start to apply configuration"
fi

bash "${SCRIPT_DIR}/configure-admin-roles.sh" || warn "admin role configuration failed (non-fatal)"

log "Post-install configuration completed"
