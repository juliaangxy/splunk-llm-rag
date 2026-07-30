#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_root

OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
# JSON array of {"source": "...", "alias": "..."} objects.
# Falls back to single-model env vars for backward compatibility.
OLLAMA_MODELS_JSON="${OLLAMA_MODELS_JSON:-}"
OLLAMA_MODEL_SOURCE="${OLLAMA_MODEL_SOURCE:-llama3.1:8b}"
OLLAMA_MODEL_ALIAS="${OLLAMA_MODEL_ALIAS:-foundation-sec-8b}"
AI_ARTIFACTS_BUCKET="${AI_ARTIFACTS_BUCKET:-}"
OLLAMA_MODEL_S3_PREFIX="${OLLAMA_MODEL_S3_PREFIX:-}"
OLLAMA_IMPORT_ROOT="${OLLAMA_IMPORT_ROOT:-/opt/splunk-ai/ollama-models}"

# Build effective models JSON from OLLAMA_MODELS_JSON or fall back to single-model env vars
if [[ -z "${OLLAMA_MODELS_JSON}" ]]; then
	OLLAMA_MODELS_JSON="[{\"source\":\"${OLLAMA_MODEL_SOURCE}\",\"alias\":\"${OLLAMA_MODEL_ALIAS}\"}]"
fi

normalize_s3_prefix() {
	local prefix="${1}"
	if [[ -n "${prefix}" && "${prefix}" != */ ]]; then
		prefix="${prefix}/"
	fi
	echo "${prefix}"
}

import_ollama_bundle_dir() {
	local bundle_dir="${1}"
	local model_name="${2}"
	local container_dir="/tmp/ollama-import/${model_name}"

	log "Importing Ollama model ${model_name} from ${bundle_dir}"
	docker exec ollama rm -f "${container_dir}" >/dev/null 2>&1 || true
	docker exec ollama mkdir -p "${container_dir}"
	docker cp "${bundle_dir}/." "ollama:${container_dir}/"
	docker exec -w "${container_dir}" ollama ollama create "${model_name}" -f Modelfile
}

import_models_from_s3() {
	require_env AI_ARTIFACTS_BUCKET
	require_cmd aws

	local normalized_prefix
	normalized_prefix="$(normalize_s3_prefix "${OLLAMA_MODEL_S3_PREFIX}")"
	if [[ -z "${normalized_prefix}" ]]; then
		error "OLLAMA_MODEL_S3_PREFIX must not be empty when AI_ARTIFACTS_BUCKET is set"
		return 1
	fi

	log "Syncing Ollama model bundles from s3://${AI_ARTIFACTS_BUCKET}/${normalized_prefix}"
	rm -rf "${OLLAMA_IMPORT_ROOT}"
	mkdir -p "${OLLAMA_IMPORT_ROOT}"
	aws s3 sync "s3://${AI_ARTIFACTS_BUCKET}/${normalized_prefix}" "${OLLAMA_IMPORT_ROOT}" --only-show-errors

	# Single-bundle at root: use first alias from OLLAMA_MODELS_JSON
	if [[ -f "${OLLAMA_IMPORT_ROOT}/Modelfile" ]]; then
		local first_alias
		first_alias=$(python3 -c "
import json, os
models = json.loads(os.environ.get('OLLAMA_MODELS_JSON', '[]'))
print(models[0]['alias'] if models else '${OLLAMA_MODEL_ALIAS}')
")
		import_ollama_bundle_dir "${OLLAMA_IMPORT_ROOT}" "${first_alias}"
		docker exec ollama ollama list | awk '{print $1}' | grep -qx "${first_alias}"
		log "Model ${first_alias} is available from S3 bundle"
		return 0
	fi

	local bundle_dir
	local imported_count=0
	while IFS= read -r bundle_dir; do
		local model_name
		model_name="$(basename "${bundle_dir}")"
		import_ollama_bundle_dir "${bundle_dir}" "${model_name}"
		imported_count=$((imported_count + 1))
	done < <(find "${OLLAMA_IMPORT_ROOT}" -mindepth 1 -maxdepth 2 -type f -name Modelfile -exec dirname {} \; | sort -u)

	if [[ "${imported_count}" -eq 0 ]]; then
		error "No Modelfile found under s3://${AI_ARTIFACTS_BUCKET}/${normalized_prefix}. Expected a Modelfile at the prefix root or in child directories."
		return 1
	fi

	log "Imported ${imported_count} Ollama model bundle(s) from S3"
}

pull_model() {
	local source="${1}"
	local alias="${2}"

	if docker exec ollama ollama list | awk '{print $1}' | grep -qx "${alias}"; then
		log "Model ${alias} already present"
		return 0
	fi

	log "Pulling source model ${source}"
	docker exec ollama ollama pull "${source}"

	if [[ "${source}" != "${alias}" ]]; then
		log "Aliasing ${source} to ${alias}"
		docker exec ollama ollama rm "${alias}" >/dev/null 2>&1 || true
		docker exec ollama ollama cp "${source}" "${alias}"
	fi
}

verify_all_models() {
	log "Verifying all models are available via Ollama API (http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/tags)"
	local api_response
	api_response=$(curl -fsS "http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/tags")

	python3 - <<PYEOF
import json, sys, os

api_response = '''${api_response}'''
models_json = os.environ.get('OLLAMA_MODELS_JSON', '[]')

data = json.loads(api_response)
available = {m['name'] for m in data.get('models', [])}
# also index by base name (without :tag) for flexible matching
available_base = {n.split(':')[0] for n in available}

expected = json.loads(models_json)
missing = []
for m in expected:
    alias = m['alias']
    if alias not in available and alias not in available_base and alias + ':latest' not in available:
        missing.append(alias)
    else:
        print(f"[OK] {alias}")

if missing:
    for name in missing:
        print(f"[MISSING] {name}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

log "Setting up Ollama models"
wait_for_port "${OLLAMA_HOST}" "${OLLAMA_PORT}" 180

if [[ -n "${AI_ARTIFACTS_BUCKET}" ]]; then
	import_models_from_s3
	verify_all_models
	exit 0
fi

# Pull each model from OLLAMA_MODELS_JSON
while IFS=$'\t' read -r source alias; do
	pull_model "${source}" "${alias}"
done < <(python3 -c "
import json, os
models = json.loads(os.environ.get('OLLAMA_MODELS_JSON', '[]'))
for m in models:
    print(m['source'] + '\t' + m['alias'])
")

verify_all_models
log "All Ollama models are available"
