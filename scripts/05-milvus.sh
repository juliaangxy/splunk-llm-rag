#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root
ensure_state_dir

MILVUS_DIR="/opt/splunk-ai/milvus"
COMPOSE_FILE="${MILVUS_DIR}/docker-compose.yaml"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"
AI_ARTIFACTS_BUCKET="${AI_ARTIFACTS_BUCKET:-}"
MILVUS_COMPOSE_S3_PREFIX="${MILVUS_COMPOSE_S3_PREFIX:-milvus/}"

normalize_s3_prefix() {
	local prefix="${1}"
	if [[ -n "${prefix}" && "${prefix}" != */ ]]; then
		prefix="${prefix}/"
	fi
	echo "${prefix}"
}

resolve_milvus_compose_s3_prefix() {
  normalize_s3_prefix "${MILVUS_COMPOSE_S3_PREFIX}"
}

fetch_milvus_compose_from_s3() {
  if [[ -z "${AI_ARTIFACTS_BUCKET}" ]]; then
		return 1
	fi

	require_cmd aws

  local compose_prefix artifacts_uri compose_candidate
	compose_prefix="$(resolve_milvus_compose_s3_prefix)"
 	artifacts_uri="s3://${AI_ARTIFACTS_BUCKET}/${compose_prefix}"

  log "Attempting to sync Milvus artifacts from ${artifacts_uri}"
  if aws s3 sync "${artifacts_uri}" "${MILVUS_DIR}" --only-show-errors; then
    for compose_candidate in \
      "${MILVUS_DIR}/milvus-docker-compose.yml" \
      "${MILVUS_DIR}/docker-compose.yml" \
      "${MILVUS_DIR}/docker-compose.yaml"; do
      if [[ -f "${compose_candidate}" ]]; then
        cp -f "${compose_candidate}" "${COMPOSE_FILE}"
        log "Using Milvus compose downloaded from ${artifacts_uri}"
        return 0
      fi
    done

    warn "No docker compose file found under ${artifacts_uri}; expected milvus-docker-compose.yml, docker-compose.yml, or docker-compose.yaml"
    return 1
	fi

  warn "Milvus artifacts not found at ${artifacts_uri}; falling back to built-in compose"
	return 1
}

write_default_milvus_compose() {
cat > "${COMPOSE_FILE}" <<EOF
services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.12
    container_name: milvus-etcd
    restart: unless-stopped
    environment:
      ETCD_AUTO_COMPACTION_MODE: revision
      ETCD_AUTO_COMPACTION_RETENTION: '1000'
      ETCD_QUOTA_BACKEND_BYTES: '4294967296'
      ETCD_SNAPSHOT_COUNT: '50000'
    command: >
      etcd -advertise-client-urls=http://127.0.0.1:2379
      -listen-client-urls=http://0.0.0.0:2379
      --data-dir /etcd
    volumes:
      - etcd-data:/etcd

  minio:
    image: minio/minio:RELEASE.2024-06-11T03-13-30Z
    container_name: milvus-minio
    restart: unless-stopped
    command: minio server /minio_data --console-address ':9001'
    environment:
      MINIO_ROOT_USER: ${MINIO_ACCESS_KEY}
      MINIO_ROOT_PASSWORD: ${MINIO_SECRET_KEY}
    ports:
      - '9000:9000'
      - '9001:9001'
    volumes:
      - minio-data:/minio_data

  milvus:
    image: milvusdb/milvus:v2.4.8
    container_name: milvus-standalone
    restart: unless-stopped
    command: ['milvus', 'run', 'standalone']
    environment:
      ETCD_ENDPOINTS: etcd:2379
      MINIO_ADDRESS: minio:9000
    depends_on:
      - etcd
      - minio
    ports:
      - '19530:19530'
      - '9091:9091'
    volumes:
      - milvus-data:/var/lib/milvus

volumes:
  etcd-data:
  minio-data:
  milvus-data:
EOF
}

log "Deploying Milvus stack"
mkdir -p "${MILVUS_DIR}"

if ! fetch_milvus_compose_from_s3; then
	write_default_milvus_compose
fi

compose="$(compose_cmd)"
${compose} -f "${COMPOSE_FILE}" up -d

wait_for_port 127.0.0.1 19530 240
log "Milvus stack is running"
