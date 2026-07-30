#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./utils/upload-huggingface-ollama-model.sh <hf-repo-or-url> <s3-bucket> [s3-prefix] [ollama-model-name]

Downloads a public GGUF model from Hugging Face, creates an Ollama Modelfile,
and uploads the bundle to S3 for stage 04-model.sh to import.

Examples:
  ./utils/upload-huggingface-ollama-model.sh \
    https://huggingface.co/fdtn-ai/Foundation-Sec-1.1-8B-Instruct-Q8_0-GGUF \
    ai-splunk-ai-bucket \
    models/huggingface/ollama/ \
    foundation-sec-8b

Optional environment variables:
  HF_GGUF_FILE        Exact GGUF file path in the Hugging Face repo to download.
                      Required only when the repo contains multiple .gguf files.
  HF_REVISION         Hugging Face revision to download from (default: main).
  OLLAMA_SYSTEM_PROMPT
                      If set, append a SYSTEM stanza to the generated Modelfile.
  OLLAMA_TEMPLATE     If set, append a TEMPLATE stanza to the generated Modelfile.
EOF
}

if [[ $# -lt 2 || $# -gt 4 ]]; then
	usage
	exit 1
fi

HF_INPUT="$1"
S3_BUCKET="$2"
S3_PREFIX="${3:-models/huggingface/ollama/}"
OLLAMA_MODEL_NAME="${4:-}"
HF_GGUF_FILE="${HF_GGUF_FILE:-}"
HF_REVISION="${HF_REVISION:-main}"
OLLAMA_SYSTEM_PROMPT="${OLLAMA_SYSTEM_PROMPT:-}"
OLLAMA_TEMPLATE="${OLLAMA_TEMPLATE:-}"

require_cmd() {
	local cmd="$1"
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		echo "ERROR: Missing required command: ${cmd}" >&2
		exit 1
	fi
}

require_cmd aws
require_cmd curl
require_cmd jq

normalize_prefix() {
	local prefix="$1"
	if [[ -n "${prefix}" && "${prefix}" != */ ]]; then
		prefix="${prefix}/"
	fi
	echo "${prefix}"
}

slugify() {
	local value="$1"
	value="$(echo "${value}" | tr '[:upper:]' '[:lower:]')"
	value="$(echo "${value}" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
	echo "${value}"
}

extract_repo_id() {
	local input="$1"
	if [[ "${input}" =~ ^https?://huggingface\.co/([^/]+/[^/?#]+) ]]; then
		echo "${BASH_REMATCH[1]}"
	else
		echo "${input}"
	fi
}

REPO_ID="$(extract_repo_id "${HF_INPUT}")"

if [[ -z "${REPO_ID}" || "${REPO_ID}" != */* ]]; then
	echo "ERROR: Could not parse Hugging Face repo id from: ${HF_INPUT}" >&2
	exit 1
fi

if [[ -z "${OLLAMA_MODEL_NAME}" ]]; then
	OLLAMA_MODEL_NAME="$(slugify "$(basename "${REPO_ID}")")"
fi

S3_PREFIX="$(normalize_prefix "${S3_PREFIX}")"
API_URL="https://huggingface.co/api/models/${REPO_ID}"
MODEL_JSON="$(mktemp)"
WORK_DIR="$(mktemp -d)"
MODEL_DIR="${WORK_DIR}/${OLLAMA_MODEL_NAME}"

cleanup() {
	rm -f "${MODEL_JSON}"
	rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "Fetching model metadata for ${REPO_ID}" >&2
curl -fsSL "${API_URL}" -o "${MODEL_JSON}"

if [[ -z "${HF_GGUF_FILE}" ]]; then
	gguf_files=()
	while IFS= read -r gguf_file; do
		if [[ -n "${gguf_file}" ]]; then
			gguf_files+=("${gguf_file}")
		fi
	done < <(jq -r '.siblings[]?.rfilename | select(test("\\.gguf$"; "i"))' "${MODEL_JSON}")
	if [[ "${#gguf_files[@]}" -eq 0 ]]; then
		echo "ERROR: No .gguf files found in Hugging Face repo ${REPO_ID}" >&2
		exit 1
	fi
	if [[ "${#gguf_files[@]}" -gt 1 ]]; then
		echo "ERROR: Multiple .gguf files found in ${REPO_ID}. Set HF_GGUF_FILE to one of:" >&2
		printf '  - %s\n' "${gguf_files[@]}" >&2
		exit 1
	fi
	HF_GGUF_FILE="${gguf_files[0]}"
fi

mkdir -p "${MODEL_DIR}"
GGUF_BASENAME="$(basename "${HF_GGUF_FILE}")"
GGUF_URL="https://huggingface.co/${REPO_ID}/resolve/${HF_REVISION}/${HF_GGUF_FILE}?download=true"

echo "Downloading ${HF_GGUF_FILE} from ${REPO_ID}" >&2
curl -fL "${GGUF_URL}" -o "${MODEL_DIR}/${GGUF_BASENAME}"

cat > "${MODEL_DIR}/Modelfile" <<EOF
FROM ./${GGUF_BASENAME}
EOF

if [[ -n "${OLLAMA_SYSTEM_PROMPT}" ]]; then
	cat >> "${MODEL_DIR}/Modelfile" <<EOF

SYSTEM """${OLLAMA_SYSTEM_PROMPT}"""
EOF
fi

if [[ -n "${OLLAMA_TEMPLATE}" ]]; then
	cat >> "${MODEL_DIR}/Modelfile" <<EOF

TEMPLATE """${OLLAMA_TEMPLATE}"""
EOF
fi

TARGET_URI="s3://${S3_BUCKET}/${S3_PREFIX}${OLLAMA_MODEL_NAME}/"
echo "Uploading Ollama bundle to ${TARGET_URI}" >&2
aws s3 sync "${MODEL_DIR}" "${TARGET_URI}" --delete

echo "Uploaded model bundle for ${OLLAMA_MODEL_NAME}" >&2
echo "S3 location: ${TARGET_URI}" >&2
echo "GGUF file: ${HF_GGUF_FILE}" >&2
