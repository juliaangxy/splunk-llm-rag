#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./utils/upload-milvus-compose-artifacts.sh <s3-bucket> [s3-prefix] [compose-source-url] [extra-artifact-url ...]

Downloads Milvus docker-compose artifacts locally and uploads them to S3.
Stage 05 bootstrap can then fetch and run the compose file from S3.

Defaults:
	s3-prefix: milvus/
  source-url: https://raw.githubusercontent.com/splunk/splunk-mltk-container-docker/v5.2/beta_content/passive_deployment_prototypes/prototype_ollama_example/compose_files/milvus-docker-compose.yml

Examples:
  ./utils/upload-milvus-compose-artifacts.sh ai-splunk-ai-bucket
	./utils/upload-milvus-compose-artifacts.sh ai-splunk-ai-bucket milvus/
	./utils/upload-milvus-compose-artifacts.sh \
		ai-splunk-ai-bucket \
		milvus/ \
		https://example.org/milvus-docker-compose.yml \
		https://example.org/extra-config.env

Optional environment variables:
  AWS_PROFILE  AWS profile to use for AWS CLI calls.
EOF
}

if [[ $# -lt 1 ]]; then
	usage
	exit 1
fi

S3_BUCKET="$1"
shift
S3_PREFIX="${1:-milvus/}"
if [[ $# -gt 0 ]]; then
	shift
fi

COMPOSE_SOURCE_URL="${1:-https://raw.githubusercontent.com/splunk/splunk-mltk-container-docker/v5.2/beta_content/passive_deployment_prototypes/prototype_ollama_example/compose_files/milvus-docker-compose.yml}"
if [[ $# -gt 0 ]]; then
	shift
fi

require_cmd() {
	local cmd="$1"
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		echo "ERROR: Missing required command: ${cmd}" >&2
		exit 1
	fi
}

normalize_prefix() {
	local prefix="$1"
	if [[ -n "${prefix}" && "${prefix}" != */ ]]; then
		prefix="${prefix}/"
	fi
	echo "${prefix}"
}

require_cmd aws
require_cmd curl

S3_PREFIX="$(normalize_prefix "${S3_PREFIX}")"

aws_cli() {
	if [[ -n "${AWS_PROFILE:-}" ]]; then
		aws --profile "${AWS_PROFILE}" "$@"
	else
		aws "$@"
	fi
}

WORK_DIR="$(mktemp -d)"
ARTIFACT_DIR="${WORK_DIR}/artifacts"
COMPOSE_LOCAL_PATH="${ARTIFACT_DIR}/milvus-docker-compose.yml"

cleanup() {
	rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${ARTIFACT_DIR}"

echo "Downloading compose artifact: ${COMPOSE_SOURCE_URL}" >&2
curl -fsSL "${COMPOSE_SOURCE_URL}" -o "${COMPOSE_LOCAL_PATH}"

if ! grep -q '^services:' "${COMPOSE_LOCAL_PATH}"; then
	echo "ERROR: Downloaded artifact does not look like a docker compose file: ${COMPOSE_SOURCE_URL}" >&2
	exit 1
fi

if [[ $# -gt 0 ]]; then
	for extra_url in "$@"; do
		artifact_name="$(basename "${extra_url%%\?*}")"
		if [[ -z "${artifact_name}" || "${artifact_name}" == "/" ]]; then
			echo "ERROR: Could not infer artifact filename from URL: ${extra_url}" >&2
			exit 1
		fi

		echo "Downloading extra artifact: ${extra_url}" >&2
		curl -fsSL "${extra_url}" -o "${ARTIFACT_DIR}/${artifact_name}"
	done
fi

TARGET_PREFIX_URI="s3://${S3_BUCKET}/${S3_PREFIX}"

echo "Uploading artifacts to ${TARGET_PREFIX_URI}" >&2
aws_cli s3 sync "${ARTIFACT_DIR}" "${TARGET_PREFIX_URI}" --delete --only-show-errors

echo "Upload complete." >&2
echo "S3 prefix: ${TARGET_PREFIX_URI}"
echo "Compose file: ${TARGET_PREFIX_URI}milvus-docker-compose.yml"
echo "Set AI_ARTIFACTS_BUCKET='${S3_BUCKET}' and optionally MILVUS_COMPOSE_S3_PREFIX='${S3_PREFIX}' for bootstrap."
