#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ./utils/upload-huggingface-embedding-model.sh <hf-model-id-or-url> <s3-bucket> [s3-prefix]

Downloads a Hugging Face embedding model locally and uploads it to S3.
Stage 09 can then sync the model and start the DSDL CPU inference container.

Defaults:
	s3-prefix: models/huggingface/sentence-transformers/

Examples:
  ./utils/upload-huggingface-embedding-model.sh sentence-transformers/all-MiniLM-L6-v2 ai-splunk-ai-bucket
	./utils/upload-huggingface-embedding-model.sh https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2 ai-splunk-ai-bucket models/huggingface/sentence-transformers/

Optional environment variables:
  HF_TOKEN      Token for private Hugging Face repos.
  HF_REVISION   Model revision/branch/tag to download (default: main).
	HF_HUB_DISABLE_XET  Disable Xet backend (default: 1 in this script).
  AWS_PROFILE   AWS profile for S3 upload.
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
	usage
	exit 1
fi

HF_INPUT="$1"
S3_BUCKET="$2"
S3_PREFIX="${3:-models/huggingface/sentence-transformers/}"
HF_REVISION="${HF_REVISION:-main}"

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

extract_repo_id() {
	local input="$1"
	if [[ "${input}" =~ ^https?://huggingface\.co/([^/]+/[^/?#]+) ]]; then
		echo "${BASH_REMATCH[1]}"
	else
		echo "${input}"
	fi
}

repo_name_from_id() {
	local repo_id="$1"
	echo "${repo_id##*/}"
}

aws_cli() {
	if [[ -n "${AWS_PROFILE:-}" ]]; then
		aws --profile "${AWS_PROFILE}" "$@"
	else
		aws "$@"
	fi
}

ensure_hf_hub() {
	if python3 -c 'import huggingface_hub' >/dev/null 2>&1; then
		return 0
	fi

	echo "Installing huggingface_hub with pip" >&2
	python3 -m pip install --user huggingface_hub >/dev/null
}

require_cmd aws
require_cmd python3
S3_PREFIX="$(normalize_prefix "${S3_PREFIX}")"

REPO_ID="$(extract_repo_id "${HF_INPUT}")"
if [[ -z "${REPO_ID}" || "${REPO_ID}" != */* ]]; then
	echo "ERROR: Could not parse Hugging Face model id from: ${HF_INPUT}" >&2
	exit 1
fi

MODEL_NAME="$(repo_name_from_id "${REPO_ID}")"
WORK_DIR="$(mktemp -d)"
MODEL_DIR="${WORK_DIR}/${MODEL_NAME}"
TARGET_URI="s3://${S3_BUCKET}/${S3_PREFIX}${MODEL_NAME}/"

cleanup() {
	rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

ensure_hf_hub

export HF_REPO_ID="${REPO_ID}"
export HF_DEST_DIR="${MODEL_DIR}"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
# Raise the per-request read timeout (default 10s) so a slow chunk doesn't abort the run.
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-60}"

python3 - <<'PY'
import os
import time
from huggingface_hub import snapshot_download

repo_id = os.environ["HF_REPO_ID"]
dest_dir = os.environ["HF_DEST_DIR"]
# Treat an empty HF_TOKEN as "no token" (anonymous). A literal "" would be sent as an
# empty `Authorization: Bearer ` header, which httpx rejects (Illegal header value).
token = os.environ.get("HF_TOKEN") or None
revision = os.environ.get("HF_REVISION", "main")

# Fetch only what a sentence-transformers / transformers model needs (PyTorch or
# safetensors weights + configs + tokenizer). Skipping the alternate format variants
# (ONNX, OpenVINO, TF, Rust, CoreML, msgpack) cuts a repo like all-MiniLM-L6-v2 from
# ~900MB to ~90MB, which also makes the download far less likely to time out.
ignore_patterns = [
    "*.onnx", "onnx/*", "onnx_*/*", "openvino/*", "*.h5", "tf_model.*",
    "rust_model.*", "*.ot", "flax_model.*", "coreml/*", "*.mlmodel", "*.msgpack",
]

last_exc = None
for attempt in range(1, 5):
    try:
        # snapshot_download skips already-complete files, so each retry resumes cheaply.
        snapshot_download(
            repo_id=repo_id,
            local_dir=dest_dir,
            revision=revision,
            token=token,
            ignore_patterns=ignore_patterns,
            max_workers=4,
        )
        break
    except Exception as exc:  # noqa: BLE001 - retry transient network errors
        last_exc = exc
        print(f"download attempt {attempt} failed: {exc}; retrying...", flush=True)
        time.sleep(5 * attempt)
else:
    raise SystemExit(f"snapshot_download failed after retries: {last_exc}")
PY

if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
	echo "ERROR: Downloaded model is missing config.json in ${MODEL_DIR}" >&2
	exit 1
fi

echo "Uploading embedding model to ${TARGET_URI}" >&2
aws_cli s3 sync "${MODEL_DIR}" "${TARGET_URI}" --delete --only-show-errors

echo "Upload complete." >&2
echo "S3 model path: ${TARGET_URI}"
echo "Use DSDL_EMBEDDING_MODEL_S3_PREFIX='${S3_PREFIX}${MODEL_NAME}/' for bootstrap overrides if needed."
