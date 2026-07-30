#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:latest}"
OLLAMA_CONTAINER_NAME="${OLLAMA_CONTAINER_NAME:-ollama}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

log "Deploying Ollama service"
docker volume create ollama-data >/dev/null

if docker ps -a --format '{{.Names}}' | grep -qx "${OLLAMA_CONTAINER_NAME}"; then
	docker rm -f "${OLLAMA_CONTAINER_NAME}" >/dev/null
fi

# Pull from ECR when airgapped (OLLAMA_IMAGE is set to an ECR URI by deploy.sh).
ensure_image "${OLLAMA_IMAGE}"

docker run -d \
	--name "${OLLAMA_CONTAINER_NAME}" \
	--gpus all \
	--restart unless-stopped \
	-p "${OLLAMA_PORT}:11434" \
	-v ollama-data:/root/.ollama \
	"${OLLAMA_IMAGE}" >/dev/null

wait_for_port 127.0.0.1 "${OLLAMA_PORT}" 180
retry 10 6 curl -fsS "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null
log "Ollama is running on port ${OLLAMA_PORT}"
