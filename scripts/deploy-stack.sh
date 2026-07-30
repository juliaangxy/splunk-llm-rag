#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploy CloudFormation stack for a target environment and region.
# Automatically resolves latest NVIDIA DLAMI ID unless explicitly provided.
# SSH CIDR and Splunk UI CIDR are mandatory user input.
# Internal service CIDRs default to VPC CIDR unless overridden.

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <environment: dev|staging|prod> <region> [ami-id]" >&2
  echo "Required env vars: ALLOWED_SSH_CIDR, ALLOWED_SPLUNK_UI_CIDR, SPLUNK_ADMIN_PASSWORD" >&2
  echo "Optional env vars: ALLOWED_SSH_CIDR, ALLOWED_SPLUNK_UI_CIDR, INSTANCE_TYPE, VPC_CIDR, ALLOWED_DOCKER_CIDR, ALLOWED_DSDL_CIDR, ALLOWED_OLLAMA_CIDR, ALLOWED_OLLAMA_INTERNAL_CIDR, ALLOWED_MILVUS_CIDR, LICENSE_BUCKET, SPLUNK_PACKAGE_URL, SPLUNK_PACKAGE_S3_KEY, SPLUNK_PACKAGE_S3_PREFIX, CONTAINER_IMAGE_PROFILES_JSON, SPLUNK_MLTK_GPU_IMAGE, SPLUNK_LLM_RAG_IMAGE, SPLUNK_LLM_RAG_HOST_PORT, DSDL_DOCKER_HOST, DSDL_ENDPOINT_URL, DSDL_EXTERNAL_URL, DSDL_DOCKER_NETWORK, AI_ARTIFACTS_BUCKET, OLLAMA_MODEL_S3_PREFIX, LICENSES_S3_PREFIX, SPLUNK_APP_S3_KEYS, SPLUNK_APPS_S3_PREFIX, RAG_MODEL_NAME, CREATE_SNAPSHOT_ON_SUCCESS, REQUIRE_BOOTSTRAP_SUCCESS, SKIP_SPLUNK_APPS_BOOTSTRAP, PROVISION_SHARED_INFRASTRUCTURE, SHARED_RESOURCE_NAME_PREFIX, SHARED_STACK_NAME, PROVISION_SHARED_S3_BUCKETS, PROVISION_SHARED_ECR_REPOSITORIES, SHARED_LICENSE_BUCKET_NAME, SHARED_AI_ARTIFACTS_BUCKET_NAME" >&2
  exit 1
fi

ENVIRONMENT="${1}"
REGION="${2}"
AMI_ID="${3:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"
LICENSE_BUCKET="${LICENSE_BUCKET:-}"
SPLUNK_PACKAGE_URL="${SPLUNK_PACKAGE_URL:-}"
SPLUNK_PACKAGE_S3_KEY="${SPLUNK_PACKAGE_S3_KEY:-}"
SPLUNK_PACKAGE_S3_PREFIX="${SPLUNK_PACKAGE_S3_PREFIX:-}"
CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON:-}"
SPLUNK_MLTK_GPU_IMAGE="${SPLUNK_MLTK_GPU_IMAGE:-}"
SPLUNK_LLM_RAG_IMAGE="${SPLUNK_LLM_RAG_IMAGE:-}"
SPLUNK_LLM_RAG_HOST_PORT="${SPLUNK_LLM_RAG_HOST_PORT:-}"
SPLUNK_MLTK_GPU_HOST_PORT="${SPLUNK_MLTK_GPU_HOST_PORT:-}"
MLTK_CONTAINER_EXTERNAL_HOST="${MLTK_CONTAINER_EXTERNAL_HOST:-}"
DSDL_DOCKER_HOST="${DSDL_DOCKER_HOST:-}"
DSDL_ENDPOINT_URL="${DSDL_ENDPOINT_URL:-}"
DSDL_EXTERNAL_URL="${DSDL_EXTERNAL_URL:-}"
DSDL_DOCKER_NETWORK="${DSDL_DOCKER_NETWORK:-}"
DSDL_CPU_INFERENCE_IMAGE="${DSDL_CPU_INFERENCE_IMAGE:-}"
DSDL_CPU_INFERENCE_PORT="${DSDL_CPU_INFERENCE_PORT:-}"
AI_ARTIFACTS_BUCKET="${AI_ARTIFACTS_BUCKET:-}"
OLLAMA_MODEL_S3_PREFIX="${OLLAMA_MODEL_S3_PREFIX:-}"
LICENSES_S3_PREFIX="${LICENSES_S3_PREFIX:-}"

ALLOWED_SSH_CIDR="${ALLOWED_SSH_CIDR:-}"
VPC_CIDR="${VPC_CIDR:-}"
ALLOWED_SPLUNK_UI_CIDR="${ALLOWED_SPLUNK_UI_CIDR:-}"
ALLOWED_DOCKER_CIDR="${ALLOWED_DOCKER_CIDR:-}"
ALLOWED_DSDL_CIDR="${ALLOWED_DSDL_CIDR:-}"
ALLOWED_OLLAMA_CIDR="${ALLOWED_OLLAMA_CIDR:-}"
ALLOWED_OLLAMA_INTERNAL_CIDR="${ALLOWED_OLLAMA_INTERNAL_CIDR:-}"
ALLOWED_MILVUS_CIDR="${ALLOWED_MILVUS_CIDR:-}"

SPLUNK_APP_S3_KEYS="${SPLUNK_APP_S3_KEYS:-}"
SPLUNK_APPS_S3_PREFIX="${SPLUNK_APPS_S3_PREFIX:-}"
RAG_MODEL_NAME="${RAG_MODEL_NAME:-}"
CREATE_SNAPSHOT_ON_SUCCESS="${CREATE_SNAPSHOT_ON_SUCCESS:-}"
REQUIRE_BOOTSTRAP_SUCCESS="${REQUIRE_BOOTSTRAP_SUCCESS:-}"
SKIP_SPLUNK_APPS_BOOTSTRAP="${SKIP_SPLUNK_APPS_BOOTSTRAP:-}"
PROVISION_SHARED_INFRASTRUCTURE="${PROVISION_SHARED_INFRASTRUCTURE:-}"
SHARED_RESOURCE_NAME_PREFIX="${SHARED_RESOURCE_NAME_PREFIX:-}"
SHARED_STACK_NAME="${SHARED_STACK_NAME:-}"
MAIN_STACK_NAME="splunk-ai-${ENVIRONMENT}"
PROVISION_SHARED_S3_BUCKETS="${PROVISION_SHARED_S3_BUCKETS:-}"
PROVISION_SHARED_ECR_REPOSITORIES="${PROVISION_SHARED_ECR_REPOSITORIES:-}"
SHARED_LICENSE_BUCKET_NAME="${SHARED_LICENSE_BUCKET_NAME:-}"
SHARED_AI_ARTIFACTS_BUCKET_NAME="${SHARED_AI_ARTIFACTS_BUCKET_NAME:-}"

SKIP_STEP2_UPLOADS_AFTER_SHARED="${SKIP_STEP2_UPLOADS_AFTER_SHARED:-false}"
STAGE_STEP2_UPLOADS_AFTER_SHARED="${STAGE_STEP2_UPLOADS_AFTER_SHARED:-${UPLOAD_STEP2_ARTIFACTS_AFTER_SHARED:-true}}"
UPLOAD_OLLAMA_MODEL_AFTER_SHARED="${UPLOAD_OLLAMA_MODEL_AFTER_SHARED:-true}"
UPLOAD_MILVUS_ARTIFACTS_AFTER_SHARED="${UPLOAD_MILVUS_ARTIFACTS_AFTER_SHARED:-true}"
UPLOAD_EMBEDDING_MODEL_AFTER_SHARED="${UPLOAD_EMBEDDING_MODEL_AFTER_SHARED:-true}"

if [[ "${SKIP_STEP2_UPLOADS_AFTER_SHARED}" == "true" ]]; then
  STAGE_STEP2_UPLOADS_AFTER_SHARED="false"
fi

OLLAMA_HF_MODEL_SOURCE="${OLLAMA_HF_MODEL_SOURCE:-https://huggingface.co/fdtn-ai/Foundation-Sec-1.1-8B-Instruct-Q8_0-GGUF}"
OLLAMA_HF_MODEL_NAME="${OLLAMA_HF_MODEL_NAME:-foundation-sec-8b}"
MILVUS_ARTIFACTS_S3_PREFIX="${MILVUS_ARTIFACTS_S3_PREFIX:-milvus/}"
EMBEDDING_HF_MODEL_SOURCE="${EMBEDDING_HF_MODEL_SOURCE:-sentence-transformers/all-MiniLM-L6-v2}"
EMBEDDING_MODEL_S3_PREFIX="${EMBEDDING_MODEL_S3_PREFIX:-models/huggingface/sentence-transformers/}"

PARAM_FILE="${REPO_ROOT}/cloudformation/parameters/${ENVIRONMENT}.json"
LOCAL_ENV_FILE="${REPO_ROOT}/cloudformation/parameters/${ENVIRONMENT}.env"
if [[ ! -f "${PARAM_FILE}" ]]; then
  echo "ERROR: Parameter file not found: ${PARAM_FILE}" >&2
  exit 1
fi

if [[ -f "${LOCAL_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${LOCAL_ENV_FILE}"
  set +a
  echo "Loaded local environment file: ${LOCAL_ENV_FILE}"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is required" >&2
  exit 1
fi

local_env_defines_var() {
  local var_name="$1"

  if [[ ! -f "${LOCAL_ENV_FILE}" ]]; then
    return 1
  fi

  grep -Eq "^[[:space:]]*export[[:space:]]+${var_name}=" "${LOCAL_ENV_FILE}"
}

resolve_var_from_param() {
  local var_name="$1"
  local param_key="$2"
  local current_value="${!var_name:-}"

  if [[ -n "${current_value}" ]]; then
    echo "${current_value}"
    return 0
  fi

  if local_env_defines_var "${var_name}"; then
    echo "${current_value}"
    return 0
  fi

  get_param_value "${param_key}"
}

normalize_shared_resource_name_prefix() {
  local raw="$1"
  local normalized

  normalized="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')"
  normalized="$(printf '%s' "${normalized}" | sed -E 's/^-+//; s/-+$//')"

  echo "${normalized}"
}

repo_name_from_source_image() {
  local source_image="$1"
  local image_no_tag="${source_image%@*}"
  image_no_tag="${image_no_tag%:*}"
  basename "${image_no_tag}"
}

source_image_tag() {
  local source_image="$1"
  if [[ "${source_image}" == *"@"* ]]; then
    echo "latest"
    return 0
  fi

  if [[ "${source_image}" == *":"* ]]; then
    echo "${source_image##*:}"
  else
    echo "latest"
  fi
}

target_image_tag_from_source() {
  local source_image="$1"
  local repo_name source_tag
  repo_name="$(repo_name_from_source_image "${source_image}")"
  source_tag="$(source_image_tag "${source_image}")"
  echo "${repo_name}-${source_tag}"
}

build_image_uri_from_source_and_repo_uri() {
  local source_image="$1"
  local repository_uri="$2"
  local target_tag
  target_tag="$(target_image_tag_from_source "${source_image}")"
  echo "${repository_uri}:${target_tag}"
}

container_profiles_json_is_set() {
  [[ -n "${CONTAINER_IMAGE_PROFILES_JSON}" ]]
}

apply_container_profiles_json_legacy_overrides() {
  local assignments

  if ! container_profiles_json_is_set; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to parse CONTAINER_IMAGE_PROFILES_JSON" >&2
    exit 1
  fi

  assignments="$(CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" python3 - <<'PY'
import json
import os
import shlex

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

emit_shared_profile_push_mappings() {
  local mltk_repo_name="$1"
  local llm_repo_name="$2"

  CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" \
  SHARED_MLTK_REPO_NAME="${mltk_repo_name}" \
  SHARED_LLM_REPO_NAME="${llm_repo_name}" \
  python3 - <<'PY'
import json
import os

profiles = json.loads(os.environ['CONTAINER_IMAGE_PROFILES_JSON'])
if not isinstance(profiles, list):
    raise SystemExit('CONTAINER_IMAGE_PROFILES_JSON must be a JSON array')

mltk_repo = os.environ['SHARED_MLTK_REPO_NAME']
llm_repo = os.environ['SHARED_LLM_REPO_NAME']

def choose_repo(profile):
    target_repo = str(profile.get('target_repo') or '').strip()
    if target_repo:
        return target_repo
    shared_repository = str(profile.get('shared_repository') or '').strip()
    role = str(profile.get('role') or '').strip()
    if shared_repository == 'llm_rag' or role == 'llm_rag':
        return llm_repo
    return mltk_repo

for profile in profiles:
    if not isinstance(profile, dict):
        continue
    source_image = str(profile.get('source_image') or profile.get('image') or '').strip()
    if not source_image:
        continue
    print(f"{source_image}={choose_repo(profile)}")
PY
}

rewrite_container_profiles_json_for_shared_uris() {
  local mltk_repo_uri="$1"
  local llm_repo_uri="$2"

  CONTAINER_IMAGE_PROFILES_JSON="${CONTAINER_IMAGE_PROFILES_JSON}" \
  SHARED_MLTK_REPO_URI="${mltk_repo_uri}" \
  SHARED_LLM_REPO_URI="${llm_repo_uri}" \
  python3 - <<'PY'
import json
import os

profiles = json.loads(os.environ['CONTAINER_IMAGE_PROFILES_JSON'])
if not isinstance(profiles, list):
    raise SystemExit('CONTAINER_IMAGE_PROFILES_JSON must be a JSON array')

mltk_repo_uri = os.environ['SHARED_MLTK_REPO_URI']
llm_repo_uri = os.environ['SHARED_LLM_REPO_URI']

def repo_uri_for_profile(profile):
    shared_repository = str(profile.get('shared_repository') or '').strip()
    role = str(profile.get('role') or '').strip()
    if shared_repository == 'llm_rag' or role == 'llm_rag':
        return llm_repo_uri
    return mltk_repo_uri

def build_target_uri(source_image, repository_uri):
    image_no_tag = source_image.split('@', 1)[0]
    image_no_tag = image_no_tag.rsplit(':', 1)[0]
    repo_name = image_no_tag.rsplit('/', 1)[-1]
    if '@' in source_image:
        source_tag = 'latest'
    elif ':' in source_image:
        source_tag = source_image.rsplit(':', 1)[-1]
    else:
        source_tag = 'latest'
    return f"{repository_uri}:{repo_name}-{source_tag}"

updated = []
for profile in profiles:
    if not isinstance(profile, dict):
        updated.append(profile)
        continue
    new_profile = dict(profile)
    source_image = str(profile.get('source_image') or profile.get('image') or '').strip()
    if source_image:
      new_profile['image'] = build_target_uri(source_image, repo_uri_for_profile(profile))
    updated.append(new_profile)

print(json.dumps(updated, separators=(',', ':')))
PY
}

upload_step2_artifacts_after_shared() {
  local apps_dir licenses_dir file_found=0
  local default_splunk_rpm_url="https://download.splunk.com/products/splunk/releases/10.4.1/linux/splunk-10.4.1-5a009d941268.x86_64.rpm"
  local splunk_package_url="${SPLUNK_PACKAGE_URL:-${default_splunk_rpm_url}}"
  apps_dir="${REPO_ROOT}/apps"
  licenses_dir="${REPO_ROOT}/licenses"

  echo "Staging Step 2 artifacts into shared buckets"

  if [[ -d "${apps_dir}" ]]; then
    echo "Uploading Splunk app packages from ${apps_dir} to s3://${LICENSE_BUCKET}/splunk-apps/"
    aws s3 cp "${apps_dir}/" "s3://${LICENSE_BUCKET}/splunk-apps/" \
      --recursive --exclude "*" --include "*.tgz" --include "*.tar" --include "*.tar.gz" --include "*.spl"
  else
    echo "WARNING: ${apps_dir} not found; skipping Splunk app package upload"
  fi

  if [[ -d "${licenses_dir}" ]]; then
    while IFS= read -r -d '' file; do
      file_found=1
      aws s3 cp "${file}" "s3://${LICENSE_BUCKET}/licenses/$(basename "${file}" | tr ' ' '-')"
    done < <(find "${licenses_dir}" -type f \( -name "*.License" -o -name "*.lic" \) -print0)

    if [[ "${file_found}" -eq 0 ]]; then
      echo "WARNING: No .License/.lic files found under ${licenses_dir}; skipping license upload"
    fi
  else
    echo "WARNING: ${licenses_dir} not found; skipping license upload"
  fi

  if [[ -n "${splunk_package_url}" ]]; then
    local normalized_prefix rpm_filename rpm_tmp_file rpm_dest_key

    normalized_prefix="${SPLUNK_PACKAGE_S3_PREFIX}"
    if [[ -n "${normalized_prefix}" && "${normalized_prefix}" != */ ]]; then
      normalized_prefix="${normalized_prefix}/"
    fi

    rpm_filename="$(basename "${splunk_package_url%%\?*}")"
    if [[ "${rpm_filename}" != *.rpm ]]; then
      rpm_filename="splunk-enterprise.rpm"
    fi

    rpm_tmp_file="$(mktemp -t splunk-enterprise-rpm.XXXXXX)"
    rpm_dest_key="${normalized_prefix}${rpm_filename}"

    echo "Downloading Splunk RPM via URL for shared bootstrap package source"
    if command -v wget >/dev/null 2>&1; then
      wget -O "${rpm_tmp_file}" "${splunk_package_url}"
    else
      echo "WARNING: wget not found; using curl fallback for Splunk RPM download"
      curl -fL "${splunk_package_url}" -o "${rpm_tmp_file}"
    fi

    echo "Uploading Splunk RPM to s3://${LICENSE_BUCKET}/${rpm_dest_key}"
    aws s3 cp "${rpm_tmp_file}" "s3://${LICENSE_BUCKET}/${rpm_dest_key}"
    rm -f "${rpm_tmp_file}"

    if [[ -z "${SPLUNK_PACKAGE_S3_KEY}" ]]; then
      SPLUNK_PACKAGE_S3_KEY="${rpm_dest_key}"
      echo "Set SPLUNK_PACKAGE_S3_KEY=${SPLUNK_PACKAGE_S3_KEY} for this deployment"
    fi
  else
    echo "WARNING: Splunk RPM URL is empty; skipping automatic Splunk RPM upload to shared license bucket"
  fi

  if [[ "${UPLOAD_OLLAMA_MODEL_AFTER_SHARED}" == "true" ]]; then
    if [[ -x "${REPO_ROOT}/utils/upload-huggingface-ollama-model.sh" ]]; then
      echo "Uploading default Ollama model bundle to s3://${AI_ARTIFACTS_BUCKET}/"
      if ! "${REPO_ROOT}/utils/upload-huggingface-ollama-model.sh" \
        "${OLLAMA_HF_MODEL_SOURCE}" \
        "${AI_ARTIFACTS_BUCKET}" \
        "${OLLAMA_MODEL_S3_PREFIX}" \
        "${OLLAMA_HF_MODEL_NAME}"; then
        echo "WARNING: Ollama model upload failed; continuing deployment"
      fi
    else
      echo "WARNING: utils/upload-huggingface-ollama-model.sh not executable; skipping Ollama model upload"
    fi
  fi

  if [[ "${UPLOAD_MILVUS_ARTIFACTS_AFTER_SHARED}" == "true" ]]; then
    if [[ -x "${REPO_ROOT}/utils/upload-milvus-compose-artifacts.sh" ]]; then
      echo "Uploading Milvus compose artifacts to s3://${AI_ARTIFACTS_BUCKET}/${MILVUS_ARTIFACTS_S3_PREFIX}"
      if ! "${REPO_ROOT}/utils/upload-milvus-compose-artifacts.sh" \
        "${AI_ARTIFACTS_BUCKET}" \
        "${MILVUS_ARTIFACTS_S3_PREFIX}"; then
        echo "WARNING: Milvus artifact upload failed; continuing deployment"
      fi
    else
      echo "WARNING: utils/upload-milvus-compose-artifacts.sh not executable; skipping Milvus artifact upload"
    fi
  fi

  if [[ "${UPLOAD_EMBEDDING_MODEL_AFTER_SHARED}" == "true" ]]; then
    if [[ -x "${REPO_ROOT}/utils/upload-huggingface-embedding-model.sh" ]]; then
      echo "Uploading embedding model artifacts to s3://${AI_ARTIFACTS_BUCKET}/${EMBEDDING_MODEL_S3_PREFIX}"
      if ! "${REPO_ROOT}/utils/upload-huggingface-embedding-model.sh" \
        "${EMBEDDING_HF_MODEL_SOURCE}" \
        "${AI_ARTIFACTS_BUCKET}" \
        "${EMBEDDING_MODEL_S3_PREFIX}"; then
        echo "WARNING: Embedding model upload failed; continuing deployment"
      fi
    else
      echo "WARNING: utils/upload-huggingface-embedding-model.sh not executable; skipping embedding model upload"
    fi
  fi
}

get_param_value() {
  local key="$1"
  local value
  value="$(jq -r --arg k "${key}" '.[] | select(.ParameterKey==$k) | .ParameterValue' "${PARAM_FILE}" | head -n1)"
  if [[ "${value}" == "null" ]]; then
    value=""
  fi
  echo "${value}"
}

INSTANCE_TYPE="$(resolve_var_from_param INSTANCE_TYPE InstanceType)"
SPLUNK_ADMIN_USER="$(resolve_var_from_param SPLUNK_ADMIN_USER SplunkAdminUser)"
ALLOWED_SSH_CIDR="$(resolve_var_from_param ALLOWED_SSH_CIDR AllowedSshCidr)"
ALLOWED_SPLUNK_UI_CIDR="$(resolve_var_from_param ALLOWED_SPLUNK_UI_CIDR AllowedSplunkUiCidr)"
ALLOWED_DOCKER_CIDR="$(resolve_var_from_param ALLOWED_DOCKER_CIDR AllowedDockerCidr)"
ALLOWED_DSDL_CIDR="$(resolve_var_from_param ALLOWED_DSDL_CIDR AllowedDsdlCidr)"
ALLOWED_OLLAMA_CIDR="$(resolve_var_from_param ALLOWED_OLLAMA_CIDR AllowedOllamaCidr)"
ALLOWED_OLLAMA_INTERNAL_CIDR="$(resolve_var_from_param ALLOWED_OLLAMA_INTERNAL_CIDR AllowedOllamaInternalCidr)"
ALLOWED_MILVUS_CIDR="$(resolve_var_from_param ALLOWED_MILVUS_CIDR AllowedMilvusCidr)"
SPLUNK_PACKAGE_URL="$(resolve_var_from_param SPLUNK_PACKAGE_URL SplunkPackageUrl)"
LICENSE_BUCKET="$(resolve_var_from_param LICENSE_BUCKET LicenseBucket)"
SPLUNK_PACKAGE_S3_KEY="$(resolve_var_from_param SPLUNK_PACKAGE_S3_KEY SplunkPackageS3Key)"
SPLUNK_PACKAGE_S3_PREFIX="$(resolve_var_from_param SPLUNK_PACKAGE_S3_PREFIX SplunkPackageS3Prefix)"
SPLUNK_MLTK_GPU_IMAGE="$(resolve_var_from_param SPLUNK_MLTK_GPU_IMAGE SplunkMltkGpuImage)"
SPLUNK_LLM_RAG_IMAGE="$(resolve_var_from_param SPLUNK_LLM_RAG_IMAGE SplunkLlmRagImage)"
SPLUNK_LLM_RAG_HOST_PORT="$(resolve_var_from_param SPLUNK_LLM_RAG_HOST_PORT SplunkLlmRagHostPort)"
SPLUNK_MLTK_GPU_HOST_PORT="$(resolve_var_from_param SPLUNK_MLTK_GPU_HOST_PORT SplunkMltkGpuHostPort)"
MLTK_CONTAINER_EXTERNAL_HOST="$(resolve_var_from_param MLTK_CONTAINER_EXTERNAL_HOST MltkContainerExternalHost)"
DSDL_DOCKER_HOST="$(resolve_var_from_param DSDL_DOCKER_HOST DsdlDockerHost)"
DSDL_ENDPOINT_URL="$(resolve_var_from_param DSDL_ENDPOINT_URL DsdlEndpointUrl)"
DSDL_EXTERNAL_URL="$(resolve_var_from_param DSDL_EXTERNAL_URL DsdlExternalUrl)"
DSDL_DOCKER_NETWORK="$(resolve_var_from_param DSDL_DOCKER_NETWORK DsdlDockerNetwork)"
DSDL_CPU_INFERENCE_IMAGE="$(resolve_var_from_param DSDL_CPU_INFERENCE_IMAGE DsdlCpuInferenceImage)"
DSDL_CPU_INFERENCE_PORT="$(resolve_var_from_param DSDL_CPU_INFERENCE_PORT DsdlCpuInferencePort)"
AI_ARTIFACTS_BUCKET="$(resolve_var_from_param AI_ARTIFACTS_BUCKET AiArtifactsBucket)"
OLLAMA_MODEL_S3_PREFIX="$(resolve_var_from_param OLLAMA_MODEL_S3_PREFIX OllamaModelS3Prefix)"
LICENSES_S3_PREFIX="$(resolve_var_from_param LICENSES_S3_PREFIX LicenseS3Prefix)"
SPLUNK_APP_S3_KEYS="$(resolve_var_from_param SPLUNK_APP_S3_KEYS SplunkAppS3Keys)"
SPLUNK_APPS_S3_PREFIX="$(resolve_var_from_param SPLUNK_APPS_S3_PREFIX SplunkAppsS3Prefix)"
RAG_MODEL_NAME="$(resolve_var_from_param RAG_MODEL_NAME RagModelName)"
CREATE_SNAPSHOT_ON_SUCCESS="$(resolve_var_from_param CREATE_SNAPSHOT_ON_SUCCESS CreateSnapshotOnSuccess)"
REQUIRE_BOOTSTRAP_SUCCESS="$(resolve_var_from_param REQUIRE_BOOTSTRAP_SUCCESS RequireBootstrapSuccess)"
SKIP_SPLUNK_APPS_BOOTSTRAP="$(resolve_var_from_param SKIP_SPLUNK_APPS_BOOTSTRAP SkipSplunkAppsBootstrap)"
PROVISION_SHARED_INFRASTRUCTURE="$(resolve_var_from_param PROVISION_SHARED_INFRASTRUCTURE ProvisionSharedInfrastructure)"
SHARED_RESOURCE_NAME_PREFIX="$(resolve_var_from_param SHARED_RESOURCE_NAME_PREFIX SharedResourceNamePrefix)"
PROVISION_SHARED_S3_BUCKETS="$(resolve_var_from_param PROVISION_SHARED_S3_BUCKETS ProvisionS3Buckets)"
PROVISION_SHARED_ECR_REPOSITORIES="$(resolve_var_from_param PROVISION_SHARED_ECR_REPOSITORIES ProvisionEcrRepositories)"
SHARED_LICENSE_BUCKET_NAME="$(resolve_var_from_param SHARED_LICENSE_BUCKET_NAME LicenseBucket)"
SHARED_AI_ARTIFACTS_BUCKET_NAME="$(resolve_var_from_param SHARED_AI_ARTIFACTS_BUCKET_NAME AiArtifactsBucket)"

if [[ -z "${SPLUNK_PACKAGE_S3_PREFIX}" ]]; then
  SPLUNK_PACKAGE_S3_PREFIX="splunk-rpms/"
fi
if [[ -z "${DSDL_DOCKER_HOST}" ]]; then
  DSDL_DOCKER_HOST="tcp://127.0.0.1:2375"
fi
if [[ -z "${SPLUNK_LLM_RAG_HOST_PORT}" ]]; then
  SPLUNK_LLM_RAG_HOST_PORT="5001"
fi
if [[ -z "${DSDL_CPU_INFERENCE_PORT}" ]]; then
  DSDL_CPU_INFERENCE_PORT="5002"
fi
if [[ -z "${SPLUNK_MLTK_GPU_HOST_PORT}" ]]; then
  SPLUNK_MLTK_GPU_HOST_PORT="5003"
fi

apply_container_profiles_json_legacy_overrides
if [[ -z "${DSDL_ENDPOINT_URL}" ]]; then
  DSDL_ENDPOINT_URL="https://127.0.0.1:2375"
fi
if [[ -z "${DSDL_EXTERNAL_URL}" ]]; then
  DSDL_EXTERNAL_URL="https://127.0.0.1:2375"
fi
if [[ -z "${DSDL_DOCKER_NETWORK}" ]]; then
  DSDL_DOCKER_NETWORK="dsenv-network"
fi
if [[ -z "${OLLAMA_MODEL_S3_PREFIX}" ]]; then
  OLLAMA_MODEL_S3_PREFIX="models/huggingface/ollama/"
fi
if [[ -z "${SPLUNK_APPS_S3_PREFIX}" ]]; then
  SPLUNK_APPS_S3_PREFIX="splunk-apps/"
fi
if [[ -z "${LICENSES_S3_PREFIX}" ]]; then
  LICENSES_S3_PREFIX="licenses/"
fi
if [[ -z "${CREATE_SNAPSHOT_ON_SUCCESS}" ]]; then
  CREATE_SNAPSHOT_ON_SUCCESS="true"
fi
if [[ -z "${REQUIRE_BOOTSTRAP_SUCCESS}" ]]; then
  REQUIRE_BOOTSTRAP_SUCCESS="true"
fi
if [[ -z "${SKIP_SPLUNK_APPS_BOOTSTRAP}" ]]; then
  SKIP_SPLUNK_APPS_BOOTSTRAP="false"
fi
if [[ -z "${PROVISION_SHARED_INFRASTRUCTURE}" ]]; then
  PROVISION_SHARED_INFRASTRUCTURE="false"
fi
if [[ -z "${PROVISION_SHARED_S3_BUCKETS}" ]]; then
  PROVISION_SHARED_S3_BUCKETS="true"
fi
if [[ -z "${PROVISION_SHARED_ECR_REPOSITORIES}" ]]; then
  PROVISION_SHARED_ECR_REPOSITORIES="true"
fi

if [[ -z "${SHARED_STACK_NAME}" ]]; then
  SHARED_STACK_NAME="splunk-ai-shared-${ENVIRONMENT}"
fi

if [[ "${PROVISION_SHARED_INFRASTRUCTURE}" == "true" && -z "${SHARED_RESOURCE_NAME_PREFIX}" ]]; then
  SHARED_RESOURCE_NAME_PREFIX="ai-splunk-shared"
  echo "SHARED_RESOURCE_NAME_PREFIX not set; defaulting to '${SHARED_RESOURCE_NAME_PREFIX}'"
fi

if [[ -n "${SHARED_RESOURCE_NAME_PREFIX}" ]]; then
  RAW_SHARED_RESOURCE_NAME_PREFIX="${SHARED_RESOURCE_NAME_PREFIX}"
  SHARED_RESOURCE_NAME_PREFIX="$(normalize_shared_resource_name_prefix "${SHARED_RESOURCE_NAME_PREFIX}")"
  if [[ "${RAW_SHARED_RESOURCE_NAME_PREFIX}" != "${SHARED_RESOURCE_NAME_PREFIX}" ]]; then
    echo "Normalized SHARED_RESOURCE_NAME_PREFIX to '${SHARED_RESOURCE_NAME_PREFIX}'"
  fi
fi

if [[ "${PROVISION_SHARED_INFRASTRUCTURE}" == "true" && -z "${SHARED_RESOURCE_NAME_PREFIX}" ]]; then
  echo "ERROR: SHARED_RESOURCE_NAME_PREFIX is required when PROVISION_SHARED_INFRASTRUCTURE=true." >&2
  exit 1
fi

if [[ -n "${SHARED_RESOURCE_NAME_PREFIX}" && ! "${SHARED_RESOURCE_NAME_PREFIX}" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
  echo "ERROR: SHARED_RESOURCE_NAME_PREFIX must be lowercase alphanumeric or hyphens and start and end with an alphanumeric character." >&2
  exit 1
fi

if [[ -z "${ALLOWED_SSH_CIDR}" ]]; then
  echo "ERROR: ALLOWED_SSH_CIDR is required." >&2
  exit 1
fi

if [[ -z "${ALLOWED_SPLUNK_UI_CIDR}" ]]; then
  echo "ERROR: ALLOWED_SPLUNK_UI_CIDR is required." >&2
  exit 1
fi

if [[ -z "${SPLUNK_ADMIN_PASSWORD}" ]]; then
  echo "ERROR: SPLUNK_ADMIN_PASSWORD is required." >&2
  exit 1
fi

if [[ -n "${SPLUNK_PACKAGE_URL}" && -n "${SPLUNK_PACKAGE_S3_KEY}" ]]; then
  echo "Using SPLUNK_PACKAGE_S3_KEY; SPLUNK_PACKAGE_URL will be ignored by bootstrap package source precedence"
fi
if [[ -n "${SPLUNK_PACKAGE_S3_KEY}" && -n "${SPLUNK_PACKAGE_S3_PREFIX}" ]]; then
  echo "Using SPLUNK_PACKAGE_S3_KEY; SPLUNK_PACKAGE_S3_PREFIX will be ignored by bootstrap package source precedence"
fi
if [[ -z "${SPLUNK_PACKAGE_S3_KEY}" && -n "${SPLUNK_PACKAGE_URL}" && -n "${SPLUNK_PACKAGE_S3_PREFIX}" ]]; then
  echo "Using SPLUNK_PACKAGE_S3_PREFIX first; SPLUNK_PACKAGE_URL will be used as fallback if no RPM is found under the prefix"
fi

if [[ -z "${VPC_CIDR}" ]]; then
  VPC_CIDR="$(jq -r '.[] | select(.ParameterKey=="VpcCidr") | .ParameterValue' "${PARAM_FILE}" | head -n1)"
fi

if [[ -z "${VPC_CIDR}" || "${VPC_CIDR}" == "null" ]]; then
  VPC_CIDR="10.0.0.0/16"
fi

if [[ "${PROVISION_SHARED_INFRASTRUCTURE}" == "true" ]]; then
  echo "Shared infrastructure provisioning enabled with prefix: ${SHARED_RESOURCE_NAME_PREFIX}"
  echo "Resolved SharedResourceNamePrefix (quoted): '$(printf '%q' "${SHARED_RESOURCE_NAME_PREFIX}")'"
  echo "Shared stack parameter sources: ProvisionS3Buckets=${PROVISION_SHARED_S3_BUCKETS}, ProvisionEcrRepositories=${PROVISION_SHARED_ECR_REPOSITORIES}"
else
  echo "Skipping shared infrastructure stack provisioning"
fi

DEPLOY_TIMESTAMP="$(date '+%d-%m-%Y-%H-%M')"
MAIN_ARTIFACT_PREFIX="${MAIN_STACK_NAME}-${DEPLOY_TIMESTAMP}"
SHARED_ARTIFACT_PREFIX="${SHARED_STACK_NAME}-${DEPLOY_TIMESTAMP}"

ALLOWED_DOCKER_CIDR="${ALLOWED_DOCKER_CIDR:-${VPC_CIDR}}"
ALLOWED_DSDL_CIDR="${ALLOWED_DSDL_CIDR:-${VPC_CIDR}}"
ALLOWED_OLLAMA_CIDR="${ALLOWED_OLLAMA_CIDR:-${ALLOWED_SSH_CIDR}}"
ALLOWED_OLLAMA_INTERNAL_CIDR="${ALLOWED_OLLAMA_INTERNAL_CIDR:-${VPC_CIDR}}"
ALLOWED_MILVUS_CIDR="${ALLOWED_MILVUS_CIDR:-${VPC_CIDR}}"

if [[ -z "${AMI_ID}" ]]; then
  AMI_ID="$("${REPO_ROOT}/utils/get-dlami-ami-id.sh" "${REGION}")"
fi

echo "Using region: ${REGION}"
echo "Using AMI ID: ${AMI_ID}"
if [[ -n "${INSTANCE_TYPE}" ]]; then
  echo "Using instance type override: ${INSTANCE_TYPE}"
fi
echo "Using Splunk UI CIDR: ${ALLOWED_SPLUNK_UI_CIDR}"
echo "Using Ollama/LLM external CIDR: ${ALLOWED_OLLAMA_CIDR}"
echo "Using Ollama/LLM internal CIDR: ${ALLOWED_OLLAMA_INTERNAL_CIDR}"
echo "Using VPC CIDR default: ${VPC_CIDR}"

if [[ -n "${SPLUNK_APP_S3_KEYS}" ]]; then
  echo "Using explicit SPLUNK_APP_S3_KEYS list for app package installation"
else
  echo "Using app package discovery prefix: ${SPLUNK_APPS_S3_PREFIX}"
fi
if [[ "${SKIP_SPLUNK_APPS_BOOTSTRAP}" == "true" ]]; then
  echo "Skipping bootstrap app install stage"
fi

# Enforce region-level capacity placement by ignoring any AZ pinning keys and shared-stack-only flags.
BASE_OVERRIDES="$(jq -r '.[] | select(.ParameterKey != "PublicSubnetAz" and .ParameterKey != "AvailabilityZone" and .ParameterKey != "SubnetAvailabilityZone" and .ParameterKey != "ProvisionSharedInfrastructure" and .ParameterKey != "SharedResourceNamePrefix") | "\(.ParameterKey)=\(.ParameterValue)"' "${PARAM_FILE}" | xargs)"

CFN_ARTIFACT_BUCKET="${CFN_ARTIFACT_BUCKET:-${LICENSE_BUCKET}}"

if [[ -z "${CFN_ARTIFACT_BUCKET}" || "${CFN_ARTIFACT_BUCKET}" == "null" ]]; then
  echo "ERROR: Could not determine S3 bucket for CloudFormation packaging." >&2
  echo "Set CFN_ARTIFACT_BUCKET or include LicenseBucket in ${PARAM_FILE}." >&2
  exit 1
fi

echo "Deployment preflight:" \
  "stack(main)=${MAIN_STACK_NAME}" \
  "stack(shared)=${SHARED_STACK_NAME}" \
  "timestamp=${DEPLOY_TIMESTAMP}" \
  "artifact_bucket=${CFN_ARTIFACT_BUCKET}"
echo "Deployment preflight prefixes:" \
  "main=${MAIN_ARTIFACT_PREFIX}" \
  "shared=${SHARED_ARTIFACT_PREFIX}"

PACKAGED_TEMPLATE="/tmp/main-packaged-${ENVIRONMENT}.yaml"
PACKAGED_SHARED_TEMPLATE="/tmp/shared-packaged-${ENVIRONMENT}.yaml"
SCRIPTS_ARCHIVE="/tmp/splunk-ai-scripts-${ENVIRONMENT}.tar.gz"
SCRIPTS_S3_KEY="${MAIN_ARTIFACT_PREFIX}/splunk-ai-scripts.tar.gz"

if [[ "${PROVISION_SHARED_INFRASTRUCTURE}" == "true" ]]; then
  SHARED_MLTK_SOURCE_IMAGE="splunk/mltk-container-golden-gpu:5.2.3"
  SHARED_LLM_RAG_SOURCE_IMAGE="splunk/mltk-container-ubi-llm-rag:5.2.3"
  SHARED_DSDL_CPU_SOURCE_IMAGE="splunk/mltk-container-golden-cpu:5.2.3"

  if container_profiles_json_is_set; then
    :
  elif [[ -n "${DOCKER_SOURCE_IMAGES:-}" ]]; then
    IFS=',' read -r first_image second_image third_image _ <<< "${DOCKER_SOURCE_IMAGES}"
    first_image="$(echo "${first_image:-}" | xargs)"
    second_image="$(echo "${second_image:-}" | xargs)"
    third_image="$(echo "${third_image:-}" | xargs)"
    if [[ -n "${first_image}" ]]; then
      SHARED_MLTK_SOURCE_IMAGE="${first_image}"
    fi
    if [[ -n "${second_image}" ]]; then
      SHARED_LLM_RAG_SOURCE_IMAGE="${second_image}"
    fi
    if [[ -n "${third_image}" ]]; then
      SHARED_DSDL_CPU_SOURCE_IMAGE="${third_image}"
    fi
  fi

  echo "Packaging shared infrastructure template to s3://${CFN_ARTIFACT_BUCKET}/${SHARED_ARTIFACT_PREFIX}"
  aws cloudformation package \
    --region "${REGION}" \
    --template-file "${REPO_ROOT}/cloudformation/shared-infrastructure.yaml" \
    --s3-bucket "${CFN_ARTIFACT_BUCKET}" \
    --s3-prefix "${SHARED_ARTIFACT_PREFIX}" \
    --output-template-file "${PACKAGED_SHARED_TEMPLATE}"

  aws cloudformation deploy \
    --region "${REGION}" \
    --stack-name "${SHARED_STACK_NAME}" \
    --template-file "${PACKAGED_SHARED_TEMPLATE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      EnvironmentName="${ENVIRONMENT}" \
      SharedResourceNamePrefix="${SHARED_RESOURCE_NAME_PREFIX}" \
      LicenseBucketName="${SHARED_LICENSE_BUCKET_NAME}" \
      AiArtifactsBucketName="${SHARED_AI_ARTIFACTS_BUCKET_NAME}" \
      ProvisionS3Buckets="${PROVISION_SHARED_S3_BUCKETS}" \
      ProvisionEcrRepositories="${PROVISION_SHARED_ECR_REPOSITORIES}"

  LICENSE_BUCKET="$(aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${SHARED_STACK_NAME}" \
    --query 'Stacks[0].Outputs[?OutputKey==`LicenseBucketName`].OutputValue' \
    --output text)"

  AI_ARTIFACTS_BUCKET="$(aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${SHARED_STACK_NAME}" \
    --query 'Stacks[0].Outputs[?OutputKey==`AiArtifactsBucketName`].OutputValue' \
    --output text)"

  MLTK_GPU_REPOSITORY_URI="$(aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${SHARED_STACK_NAME}" \
    --query 'Stacks[0].Outputs[?OutputKey==`MltkGpuRepositoryUri`].OutputValue' \
    --output text)"

  LLM_RAG_REPOSITORY_URI="$(aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${SHARED_STACK_NAME}" \
    --query 'Stacks[0].Outputs[?OutputKey==`LlmRagRepositoryUri`].OutputValue' \
    --output text)"

  echo "Shared stack outputs resolved:" \
    "LICENSE_BUCKET=${LICENSE_BUCKET}" \
    "AI_ARTIFACTS_BUCKET=${AI_ARTIFACTS_BUCKET}" \
    "MLTK_GPU_REPOSITORY_URI=${MLTK_GPU_REPOSITORY_URI}" \
    "LLM_RAG_REPOSITORY_URI=${LLM_RAG_REPOSITORY_URI}"

  if [[ "${STAGE_STEP2_UPLOADS_AFTER_SHARED}" == "true" ]]; then
    upload_step2_artifacts_after_shared
  else
    echo "Skipping automatic Step 2 artifact uploads after shared stack creation"
  fi

  MLTK_GPU_REPOSITORY_NAME="$(basename "${MLTK_GPU_REPOSITORY_URI}")"
  LLM_RAG_REPOSITORY_NAME="$(basename "${LLM_RAG_REPOSITORY_URI}")"

  if [[ -z "${MLTK_GPU_REPOSITORY_URI}" || "${MLTK_GPU_REPOSITORY_URI}" == "None" || -z "${LLM_RAG_REPOSITORY_URI}" || "${LLM_RAG_REPOSITORY_URI}" == "None" ]]; then
    echo "Skipping shared ECR seeding because repository outputs are empty"
  else
    echo "Seeding required container images into shared ECR repositories"
    if container_profiles_json_is_set; then
      mapfile -t shared_push_mappings < <(emit_shared_profile_push_mappings "${MLTK_GPU_REPOSITORY_NAME}" "${LLM_RAG_REPOSITORY_NAME}")
      ECR_REPOSITORY_NAME="" "${REPO_ROOT}/utils/push-docker-images-to-ecr.sh" "${REGION}" "${shared_push_mappings[@]}"
      CONTAINER_IMAGE_PROFILES_JSON="$(rewrite_container_profiles_json_for_shared_uris "${MLTK_GPU_REPOSITORY_URI}" "${LLM_RAG_REPOSITORY_URI}")"
      apply_container_profiles_json_legacy_overrides
    else
      ECR_REPOSITORY_NAME="" "${REPO_ROOT}/utils/push-docker-images-to-ecr.sh" "${REGION}" \
        "${SHARED_MLTK_SOURCE_IMAGE}=${MLTK_GPU_REPOSITORY_NAME}" \
        "${SHARED_LLM_RAG_SOURCE_IMAGE}=${LLM_RAG_REPOSITORY_NAME}" \
        "${SHARED_DSDL_CPU_SOURCE_IMAGE}=${MLTK_GPU_REPOSITORY_NAME}"

      SPLUNK_MLTK_GPU_IMAGE="$(build_image_uri_from_source_and_repo_uri "${SHARED_MLTK_SOURCE_IMAGE}" "${MLTK_GPU_REPOSITORY_URI}")"
      SPLUNK_LLM_RAG_IMAGE="$(build_image_uri_from_source_and_repo_uri "${SHARED_LLM_RAG_SOURCE_IMAGE}" "${LLM_RAG_REPOSITORY_URI}")"
      DSDL_CPU_INFERENCE_IMAGE="$(build_image_uri_from_source_and_repo_uri "${SHARED_DSDL_CPU_SOURCE_IMAGE}" "${MLTK_GPU_REPOSITORY_URI}")"
    fi

    echo "Configured shared ECR image URIs for main stack:" \
      "SPLUNK_MLTK_GPU_IMAGE=${SPLUNK_MLTK_GPU_IMAGE}" \
      "SPLUNK_LLM_RAG_IMAGE=${SPLUNK_LLM_RAG_IMAGE}" \
      "DSDL_CPU_INFERENCE_IMAGE=${DSDL_CPU_INFERENCE_IMAGE}"
  fi
fi

echo "Packaging main stack templates to s3://${CFN_ARTIFACT_BUCKET}/${MAIN_ARTIFACT_PREFIX}"
aws cloudformation package \
  --region "${REGION}" \
  --template-file "${REPO_ROOT}/cloudformation/main.yaml" \
  --s3-bucket "${CFN_ARTIFACT_BUCKET}" \
  --s3-prefix "${MAIN_ARTIFACT_PREFIX}" \
  --output-template-file "${PACKAGED_TEMPLATE}"

echo "Uploading bootstrap scripts archive to s3://${CFN_ARTIFACT_BUCKET}/${SCRIPTS_S3_KEY}"
tar -C "${REPO_ROOT}" -czf "${SCRIPTS_ARCHIVE}" scripts

if ! tar -tzf "${SCRIPTS_ARCHIVE}" | grep -qx 'scripts/configure-splunk-apps.yml'; then
  echo "ERROR: bootstrap archive is missing scripts/configure-splunk-apps.yml" >&2
  exit 1
fi

aws s3 cp "${SCRIPTS_ARCHIVE}" "s3://${CFN_ARTIFACT_BUCKET}/${SCRIPTS_S3_KEY}" --region "${REGION}"

BOOTSTRAP_SCRIPTS_URL="$(aws s3 presign "s3://${CFN_ARTIFACT_BUCKET}/${SCRIPTS_S3_KEY}" --region "${REGION}" --expires-in 604800)"

aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${MAIN_STACK_NAME}" \
  --template-file "${PACKAGED_TEMPLATE}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ${BASE_OVERRIDES} \
    AmiId="${AMI_ID}" \
    CfnArtifactBucket="${CFN_ARTIFACT_BUCKET}" \
    BootstrapScriptsS3Key="${SCRIPTS_S3_KEY}" \
    BootstrapScriptsUrl="${BOOTSTRAP_SCRIPTS_URL}" \
    AllowedSshCidr="${ALLOWED_SSH_CIDR}" \
    AllowedSplunkUiCidr="${ALLOWED_SPLUNK_UI_CIDR}" \
    AllowedDockerCidr="${ALLOWED_DOCKER_CIDR}" \
    AllowedDsdlCidr="${ALLOWED_DSDL_CIDR}" \
    AllowedOllamaCidr="${ALLOWED_OLLAMA_CIDR}" \
    AllowedOllamaInternalCidr="${ALLOWED_OLLAMA_INTERNAL_CIDR}" \
    AllowedMilvusCidr="${ALLOWED_MILVUS_CIDR}" \
    LicenseBucket="${LICENSE_BUCKET}" \
    SplunkAdminUser="${SPLUNK_ADMIN_USER}" \
    SplunkAdminPassword="${SPLUNK_ADMIN_PASSWORD}" \
    SplunkMltkGpuImage="${SPLUNK_MLTK_GPU_IMAGE}" \
    SplunkLlmRagImage="${SPLUNK_LLM_RAG_IMAGE}" \
    SplunkLlmRagHostPort="${SPLUNK_LLM_RAG_HOST_PORT}" \
    SplunkMltkGpuHostPort="${SPLUNK_MLTK_GPU_HOST_PORT}" \
    MltkContainerExternalHost="${MLTK_CONTAINER_EXTERNAL_HOST}" \
    DsdlDockerHost="${DSDL_DOCKER_HOST}" \
    DsdlEndpointUrl="${DSDL_ENDPOINT_URL}" \
    DsdlExternalUrl="${DSDL_EXTERNAL_URL}" \
    DsdlDockerNetwork="${DSDL_DOCKER_NETWORK}" \
    DsdlCpuInferenceImage="${DSDL_CPU_INFERENCE_IMAGE}" \
    DsdlCpuInferencePort="${DSDL_CPU_INFERENCE_PORT}" \
    AiArtifactsBucket="${AI_ARTIFACTS_BUCKET}" \
    OllamaModelS3Prefix="${OLLAMA_MODEL_S3_PREFIX}" \
    LicenseS3Prefix="${LICENSES_S3_PREFIX}" \
    SplunkPackageUrl="${SPLUNK_PACKAGE_URL}" \
    SplunkPackageS3Key="${SPLUNK_PACKAGE_S3_KEY}" \
    SplunkPackageS3Prefix="${SPLUNK_PACKAGE_S3_PREFIX}" \
    ContainerImageProfilesJson="${CONTAINER_IMAGE_PROFILES_JSON}" \
    SplunkAppS3Keys="${SPLUNK_APP_S3_KEYS}" \
    SplunkAppsS3Prefix="${SPLUNK_APPS_S3_PREFIX}" \
    RagModelName="${RAG_MODEL_NAME}" \
    CreateSnapshotOnSuccess="${CREATE_SNAPSHOT_ON_SUCCESS}" \
    RequireBootstrapSuccess="${REQUIRE_BOOTSTRAP_SUCCESS}" \
    SkipSplunkAppsBootstrap="${SKIP_SPLUNK_APPS_BOOTSTRAP}" \
    ${INSTANCE_TYPE:+InstanceType="${INSTANCE_TYPE}"}
