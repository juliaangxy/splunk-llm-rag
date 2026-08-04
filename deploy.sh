#!/usr/bin/env bash
set -euo pipefail

# Deploy the Splunk AI platform for one environment (cloud | airgapped).
#
#   ./deploy.sh <cloud|airgapped> <region> [ami-id]
#
# Assumes the aws CLI is already authenticated (SSO / aws login) in this shell.
# Flow:
#   1. Deploy the shared foundation (VPC+endpoints, 2 buckets, ECR, IAM) once.
#   2. Stage artifacts into the buckets and seed images into ECR.
#   3. Push env secrets into Secrets Manager.
#   4. Package + deploy the per-environment stack (SGs, GPU host, search head, scheduler).

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo is now flat (deploy.sh + scripts/ + utils/ + config/ all at root), so REPO_ROOT
# and PLATFORM_DIR are the same directory.
REPO_ROOT="${PLATFORM_DIR}"
CFN_DIR="${PLATFORM_DIR}/cloudformation"

usage() {
  echo "Usage: $0 <cloud|airgapped> <region> [ami-id]" >&2
  echo "Requires config/<env>.env with ALLOWED_SSH_CIDR, ALLOWED_SPLUNK_UI_CIDR, SPLUNK_ADMIN_PASSWORD." >&2
}

[[ $# -ge 2 ]] || { usage; exit 1; }

ENVIRONMENT="$1"
REGION="$2"
AMI_ID="${3:-}"

case "${ENVIRONMENT}" in
  cloud|airgapped) ;;
  *) echo "ERROR: environment must be 'cloud' or 'airgapped'" >&2; exit 1 ;;
esac

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI is required" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

PARAM_FILE="${PLATFORM_DIR}/config/${ENVIRONMENT}.json"
ENV_FILE="${PLATFORM_DIR}/config/${ENVIRONMENT}.env"
[[ -f "${PARAM_FILE}" ]] || { echo "ERROR: missing ${PARAM_FILE}" >&2; exit 1; }
[[ -f "${ENV_FILE}"   ]] || { echo "ERROR: missing ${ENV_FILE} (copy ${ENVIRONMENT}.env.example)" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

RESOURCE_NAME_PREFIX="${RESOURCE_NAME_PREFIX:-splunk-ai}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
PUBLIC_SUBNET_CIDR="${PUBLIC_SUBNET_CIDR:-10.0.1.0/24}"
STAGE_ARTIFACTS="${STAGE_ARTIFACTS:-true}"
STAGE_APPS="${STAGE_APPS:-true}"          # set false if apps are already uploaded to the bucket
SEED_ECR="${SEED_ECR:-true}"
# Bucket options (set any of these in <env>.env):
#   AI_ARTIFACTS_BUCKET / APPS_LICENSE_BUCKET        reuse existing buckets (exact names)
#   AI_ARTIFACTS_BUCKET_BASE / APPS_LICENSE_BUCKET_BASE   create with your base name + '-<random5>'
#   (none set)                                       create '<prefix>-{ai-artifacts,apps-license}-<random5>'
EXISTING_AI_BUCKET="${AI_ARTIFACTS_BUCKET:-}"
EXISTING_APPS_BUCKET="${APPS_LICENSE_BUCKET:-}"
AI_BUCKET_BASE="${AI_ARTIFACTS_BUCKET_BASE:-}"
APPS_BUCKET_BASE="${APPS_LICENSE_BUCKET_BASE:-}"

# Default Splunk RPM (used when no RPM is staged and not provided).
SPLUNK_PACKAGE_URL="${SPLUNK_PACKAGE_URL:-https://download.splunk.com/products/splunk/releases/10.4.1/linux/splunk-10.4.1-5a009d941268.x86_64.rpm}"

# Model staging sources (HF GGUF for Ollama, HF id for embeddings).
FOUNDATION_SEC_HF="${FOUNDATION_SEC_HF:-https://huggingface.co/fdtn-ai/Foundation-Sec-1.1-8B-Instruct-Q8_0-GGUF}"
# Second Ollama model — ungated + Apache-2.0 + Cisco Green (IBM Granite 3.1 2B Instruct,
# ~1.5GB at Q4_K_M). Set OLLAMA_MODEL2_HF='' to skip. Pin one GGUF file via *_GGUF_FILE.
OLLAMA_MODEL2_HF="${OLLAMA_MODEL2_HF:-https://huggingface.co/bartowski/granite-3.1-2b-instruct-GGUF}"
OLLAMA_MODEL2_ALIAS="${OLLAMA_MODEL2_ALIAS:-granite-3.1-2b}"
OLLAMA_MODEL2_GGUF_FILE="${OLLAMA_MODEL2_GGUF_FILE:-granite-3.1-2b-instruct-Q4_K_M.gguf}"
EMBEDDING_HF="${EMBEDDING_HF:-sentence-transformers/all-MiniLM-L6-v2}"
VLLM_MODEL="${VLLM_MODEL:-ibm-granite/granite-3.1-2b-instruct}"
VLLM_MODEL_S3_PREFIX="${VLLM_MODEL_S3_PREFIX:-models/vllm/granite-3.1-2b-instruct/}"

for v in ALLOWED_SSH_CIDR ALLOWED_SPLUNK_UI_CIDR SPLUNK_ADMIN_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then echo "ERROR: ${v} must be set in ${ENV_FILE}" >&2; exit 1; fi
done

if [[ -z "${AMI_ID}" ]]; then
  echo "Resolving latest NVIDIA DLAMI for ${REGION} (GPU host)"
  AMI_ID="$("${REPO_ROOT}/utils/get-dlami-ami-id.sh" "${REGION}")"
fi
# Search head runs a Splunk-supported general-purpose OS (Amazon Linux 2023), not the DLAMI.
SEARCH_HEAD_AMI_ID="${SEARCH_HEAD_AMI_ID:-}"
if [[ -z "${SEARCH_HEAD_AMI_ID}" ]]; then
  echo "Resolving latest Amazon Linux 2023 AMI for ${REGION} (search head)"
  SEARCH_HEAD_AMI_ID="$("${REPO_ROOT}/utils/get-al2023-ami-id.sh" "${REGION}")"
fi
echo "Region=${REGION}  GPU_AMI=${AMI_ID}  SH_AMI=${SEARCH_HEAD_AMI_ID}  Env=${ENVIRONMENT}  Airgapped=$( [[ ${ENVIRONMENT} == airgapped ]] && echo true || echo false )"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
stack_output() {
  local stack="$1" key="$2"
  aws cloudformation describe-stacks --region "${REGION}" --stack-name "${stack}" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" --output text
}

# Derive the ECR image tag the way push-docker-images-to-ecr.sh does: <name>-<sourceTag>.
derive_target_uri() {
  local source_image="$1" repo_uri="$2"
  python3 - "$source_image" "$repo_uri" <<'PY'
import sys
src, repo = sys.argv[1], sys.argv[2]
no_tag = src.split('@', 1)[0].rsplit(':', 1)[0]
name = no_tag.rsplit('/', 1)[-1]
if '@' in src:
    tag = 'latest'
elif ':' in src:
    tag = src.rsplit(':', 1)[-1]
else:
    tag = 'latest'
print(f"{repo}:{name}-{tag}")
PY
}

# ---------------------------------------------------------------------------
# 1. Foundation (network + storage + iam) — flat stacks, no packaging bucket needed
# ---------------------------------------------------------------------------
NET_STACK="${RESOURCE_NAME_PREFIX}-foundation-network"
STORE_STACK="${RESOURCE_NAME_PREFIX}-foundation-storage"
IAM_STACK="${RESOURCE_NAME_PREFIX}-foundation-iam"

echo "== Foundation: network =="
aws cloudformation deploy --region "${REGION}" --stack-name "${NET_STACK}" \
  --template-file "${CFN_DIR}/network.yaml" \
  --parameter-overrides ResourceNamePrefix="${RESOURCE_NAME_PREFIX}" \
    VpcCidr="${VPC_CIDR}" PublicSubnetCidr="${PUBLIC_SUBNET_CIDR}"

echo "== Foundation: storage =="
aws cloudformation deploy --region "${REGION}" --stack-name "${STORE_STACK}" \
  --template-file "${CFN_DIR}/storage.yaml" --capabilities CAPABILITY_IAM \
  --parameter-overrides ResourceNamePrefix="${RESOURCE_NAME_PREFIX}" \
    ExistingAiArtifactsBucketName="${EXISTING_AI_BUCKET}" \
    ExistingAppsLicenseBucketName="${EXISTING_APPS_BUCKET}" \
    AiArtifactsBucketBaseName="${AI_BUCKET_BASE}" \
    AppsLicenseBucketBaseName="${APPS_BUCKET_BASE}"

AI_ARTIFACTS_BUCKET="$(stack_output "${STORE_STACK}" AiArtifactsBucketName)"
APPS_LICENSE_BUCKET="$(stack_output "${STORE_STACK}" AppsLicenseBucketName)"
ECR_REGISTRY_URI="$(stack_output "${STORE_STACK}" EcrRegistryUri)"
ECR_REPOSITORY_NAME="$(stack_output "${STORE_STACK}" ContainerRepositoryName)"
ECR_REPOSITORY_URI="$(stack_output "${STORE_STACK}" ContainerRepositoryUri)"

echo "== Foundation: iam =="
aws cloudformation deploy --region "${REGION}" --stack-name "${IAM_STACK}" \
  --template-file "${CFN_DIR}/iam.yaml" --capabilities CAPABILITY_IAM \
  --parameter-overrides ResourceNamePrefix="${RESOURCE_NAME_PREFIX}" \
    AiArtifactsBucket="${AI_ARTIFACTS_BUCKET}" AppsLicenseBucket="${APPS_LICENSE_BUCKET}"

VPC_ID="$(stack_output "${NET_STACK}" VpcId)"
PUBLIC_SUBNET_ID="$(stack_output "${NET_STACK}" PublicSubnetId)"
INSTANCE_PROFILE_NAME="$(stack_output "${IAM_STACK}" InstanceProfileName)"

echo "Foundation resolved: vpc=${VPC_ID} subnet=${PUBLIC_SUBNET_ID} ai=${AI_ARTIFACTS_BUCKET} apps=${APPS_LICENSE_BUCKET} ecr=${ECR_REPOSITORY_URI}"

# ---------------------------------------------------------------------------
# 2. Stage artifacts into the buckets
# ---------------------------------------------------------------------------
if [[ "${STAGE_ARTIFACTS}" == "true" ]]; then
  echo "== Staging Splunk apps + licenses =="
  if [[ "${STAGE_APPS}" == "true" && -d "${REPO_ROOT}/apps" ]]; then
    aws s3 cp "${REPO_ROOT}/apps/" "s3://${APPS_LICENSE_BUCKET}/splunk-apps/" --recursive \
      --exclude "*" --include "*.tgz" --include "*.tar" --include "*.tar.gz" --include "*.spl"
  else
    echo "Skipping Splunk app upload (STAGE_APPS=${STAGE_APPS})"
  fi
  if [[ -d "${REPO_ROOT}/licenses" ]]; then
    while IFS= read -r -d '' f; do
      aws s3 cp "${f}" "s3://${APPS_LICENSE_BUCKET}/licenses/$(basename "${f}" | tr ' ' '-')"
    done < <(find "${REPO_ROOT}/licenses" -type f \( -name "*.License" -o -name "*.lic" -o -name "*.key" \) -print0)
  fi

  echo "== Staging Splunk RPM =="
  RPM_TMP="$(mktemp -t splunk-rpm.XXXXXX)"
  curl -fL "${SPLUNK_PACKAGE_URL}" -o "${RPM_TMP}"
  aws s3 cp "${RPM_TMP}" "s3://${APPS_LICENSE_BUCKET}/splunk-rpms/$(basename "${SPLUNK_PACKAGE_URL%%\?*}")"
  rm -f "${RPM_TMP}"

  echo "== Staging Ollama models =="
  # NOTE: the util appends the model name to the prefix, so pass the BARE prefix
  # (models/huggingface/ollama/) — it becomes models/huggingface/ollama/<name>/.
  "${REPO_ROOT}/utils/upload-huggingface-ollama-model.sh" \
    "${FOUNDATION_SEC_HF}" "${AI_ARTIFACTS_BUCKET}" "models/huggingface/ollama/" "foundation-sec-8b" \
    || echo "WARN: Foundation-Sec model staging failed; continuing"
  if [[ -n "${OLLAMA_MODEL2_HF}" ]]; then
    echo "== Staging second Ollama model (${OLLAMA_MODEL2_ALIAS}) =="
    HF_GGUF_FILE="${OLLAMA_MODEL2_GGUF_FILE}" "${REPO_ROOT}/utils/upload-huggingface-ollama-model.sh" \
      "${OLLAMA_MODEL2_HF}" "${AI_ARTIFACTS_BUCKET}" "models/huggingface/ollama/" "${OLLAMA_MODEL2_ALIAS}" \
      || echo "WARN: second Ollama model staging failed; continuing"
  else
    echo "NOTE: OLLAMA_MODEL2_HF is empty; skipping the second Ollama model."
  fi

  echo "== Staging embedding model =="
  "${REPO_ROOT}/utils/upload-huggingface-embedding-model.sh" \
    "${EMBEDDING_HF}" "${AI_ARTIFACTS_BUCKET}" "models/huggingface/sentence-transformers/" \
    || echo "WARN: embedding model staging failed; continuing"

  echo "== Staging Milvus compose =="
  "${REPO_ROOT}/utils/upload-milvus-compose-artifacts.sh" "${AI_ARTIFACTS_BUCKET}" "milvus/" \
    || echo "WARN: Milvus compose staging failed; continuing"

  # vLLM model: only the airgapped env needs it pre-staged in S3 (cloud pulls from
  # Hugging Face at runtime). The default model (IBM Granite) is UNGATED and Apache-2.0,
  # so no HF token is required to download it.
  if [[ "${ENVIRONMENT}" == "airgapped" ]]; then
    echo "== Staging vLLM model ${VLLM_MODEL} to S3 =="
    HF_TOKEN="${HF_TOKEN:-}" "${REPO_ROOT}/utils/upload-huggingface-embedding-model.sh" \
      "${VLLM_MODEL}" "${AI_ARTIFACTS_BUCKET}" "${VLLM_MODEL_S3_PREFIX}" \
      || echo "WARN: vLLM model staging failed; continuing"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Seed ECR + compute image URIs
# ---------------------------------------------------------------------------
DSDL_VERSION="${DSDL_VERSION:-5.2.4}"
MLTK_GPU_SRC="splunk/mltk-container-golden-gpu:${DSDL_VERSION}"
LLM_RAG_SRC="splunk/mltk-container-ubi-llm-rag:${DSDL_VERSION}"
CPU_SRC="splunk/mltk-container-golden-cpu:${DSDL_VERSION}"
OLLAMA_SRC="ollama/ollama:latest"
ETCD_SRC="quay.io/coreos/etcd:v3.5.12"
MINIO_SRC="minio/minio:RELEASE.2024-06-11T03-13-30Z"
MILVUS_SRC="milvusdb/milvus:v2.4.8"
CUDA_SRC="nvidia/cuda:12.4.1-base-ubuntu22.04"
VLLM_SRC="vllm/vllm-openai:latest"
PROXY_IMAGE="${ECR_REPOSITORY_URI}:token-meter-proxy-latest"

if [[ "${SEED_ECR}" == "true" ]]; then
  echo "== Seeding ECR repository ${ECR_REPOSITORY_NAME} =="

  # Build + push the tiny token-metering proxy image (both envs) so instances can pull it.
  echo "== Building + pushing token-meter proxy image =="
  aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY_URI}" >/dev/null
  # Build for the instances' arch (amd64), not the dev machine's — an arm64 Mac would
  # otherwise push an arm64 proxy image the EC2 hosts can't run. Push a CLEAN single-arch
  # image: BuildKit otherwise wraps the push in an OCI image index with an extra 0-byte
  # provenance/SBOM attestation manifest (the stray "Image Index" + untagged 0.00 MB entry
  # in ECR, which also trips `docker pull` on some clients). buildx with BOTH attestations
  # disabled + a single --platform yields one plain manifest; --push uploads it directly.
  if docker buildx version >/dev/null 2>&1; then
    docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
      -t "${PROXY_IMAGE}" --push "${PLATFORM_DIR}/token-meter-proxy"
  else
    # No buildx: the legacy builder never emits an index/attestation (single amd64 manifest).
    DOCKER_BUILDKIT=0 docker build --platform linux/amd64 -t "${PROXY_IMAGE}" "${PLATFORM_DIR}/token-meter-proxy"
    docker push "${PROXY_IMAGE}"
  fi

  if [[ "${ENVIRONMENT}" == "airgapped" ]]; then
    # Airgapped: seed ALL default Splunk DSDL images (so any default image can be
    # started from ECR), plus the non-DSDL infra images (Ollama/Milvus/etcd/MinIO/CUDA).
    ECR_REGISTRY_URI="${ECR_REGISTRY_URI}" ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME}" \
      "${PLATFORM_DIR}/scripts/dsdl/seed-default-dsdl-images.sh" "${REGION}"
    ECR_REGISTRY_URI="${ECR_REGISTRY_URI}" ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME}" \
      "${REPO_ROOT}/utils/push-docker-images-to-ecr.sh" "${REGION}" \
        "${OLLAMA_SRC}=${ECR_REPOSITORY_NAME}" "${ETCD_SRC}=${ECR_REPOSITORY_NAME}" \
        "${MINIO_SRC}=${ECR_REPOSITORY_NAME}" "${MILVUS_SRC}=${ECR_REPOSITORY_NAME}" \
        "${CUDA_SRC}=${ECR_REPOSITORY_NAME}" "${VLLM_SRC}=${ECR_REPOSITORY_NAME}"
  else
    # Cloud: only seed the DSDL/MLTK images used by the running containers (kept private);
    # infra images pull from public registries directly.
    ECR_REGISTRY_URI="${ECR_REGISTRY_URI}" ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME}" \
      "${REPO_ROOT}/utils/push-docker-images-to-ecr.sh" "${REGION}" \
        "${MLTK_GPU_SRC}=${ECR_REPOSITORY_NAME}" "${LLM_RAG_SRC}=${ECR_REPOSITORY_NAME}" \
        "${CPU_SRC}=${ECR_REPOSITORY_NAME}"
  fi
fi

MLTK_GPU_IMAGE="$(derive_target_uri "${MLTK_GPU_SRC}" "${ECR_REPOSITORY_URI}")"
LLM_RAG_IMAGE="$(derive_target_uri "${LLM_RAG_SRC}" "${ECR_REPOSITORY_URI}")"
CPU_IMAGE="$(derive_target_uri "${CPU_SRC}" "${ECR_REPOSITORY_URI}")"

# Infra image overrides: ECR when airgapped, public defaults otherwise.
if [[ "${ENVIRONMENT}" == "airgapped" ]]; then
  OLLAMA_IMAGE="$(derive_target_uri "${OLLAMA_SRC}" "${ECR_REPOSITORY_URI}")"
  ETCD_IMAGE="$(derive_target_uri "${ETCD_SRC}" "${ECR_REPOSITORY_URI}")"
  MINIO_IMAGE="$(derive_target_uri "${MINIO_SRC}" "${ECR_REPOSITORY_URI}")"
  MILVUS_IMAGE="$(derive_target_uri "${MILVUS_SRC}" "${ECR_REPOSITORY_URI}")"
  CUDA_IMAGE="$(derive_target_uri "${CUDA_SRC}" "${ECR_REPOSITORY_URI}")"
else
  OLLAMA_IMAGE="${OLLAMA_SRC}"; ETCD_IMAGE="${ETCD_SRC}"; MINIO_IMAGE="${MINIO_SRC}"
  MILVUS_IMAGE="${MILVUS_SRC}"; CUDA_IMAGE="${CUDA_SRC}"
fi

# vLLM server image: ECR when airgapped, public otherwise. The proxy image is always in ECR.
if [[ "${ENVIRONMENT}" == "airgapped" ]]; then
  VLLM_IMAGE="$(derive_target_uri "${VLLM_SRC}" "${ECR_REPOSITORY_URI}")"
else
  VLLM_IMAGE="${VLLM_SRC}"
fi

# containers.conf/images.conf profiles for DSDL/MLTK (consumed on the instances).
CONTAINER_IMAGE_PROFILES_JSON="$(MLTK="${MLTK_GPU_IMAGE}" LLM="${LLM_RAG_IMAGE}" CPU="${CPU_IMAGE}" python3 - <<'PY'
import json, os
print(json.dumps([
  {"role":"llm_rag","name":"llm_rag","source_image":os.environ["LLM"],"image":os.environ["LLM"],"host_port":5001,"mode":"DEV","runtime":"None","shared_repository":"llm_rag"},
  {"role":"cpu_container","name":"cpu_container","source_image":os.environ["CPU"],"image":os.environ["CPU"],"host_port":5002,"mode":"DEV","runtime":"None","shared_repository":"mltk_gpu"},
  {"role":"gpu_container","name":"gpu_container","source_image":os.environ["MLTK"],"image":os.environ["MLTK"],"host_port":5003,"mode":"DEV","runtime":"None","shared_repository":"mltk_gpu"},
], separators=(",", ":")))
PY
)"

# ---------------------------------------------------------------------------
# 4. Push secrets into Secrets Manager
# ---------------------------------------------------------------------------
SECRET_ID="${RESOURCE_NAME_PREFIX}/${ENVIRONMENT}"
echo "== Storing secrets in Secrets Manager: ${SECRET_ID} =="
# Generate the HEC token and proxy API key if not supplied, so BOTH instances share
# the same values (needed for token metering + the shared llm.conf api_key).
SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN:-$(python3 -c 'import uuid; print(uuid.uuid4())')}"
PROXY_API_KEY="${PROXY_API_KEY:-$(python3 -c 'import secrets; print(secrets.token_hex(24))')}"
SECRET_JSON="$(SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD}" \
  SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN}" PROXY_API_KEY="${PROXY_API_KEY}" HF_TOKEN="${HF_TOKEN:-}" python3 - <<'PY'
import json, os
out = {
    "SPLUNK_ADMIN_PASSWORD": os.environ["SPLUNK_ADMIN_PASSWORD"],
    "SPLUNK_HEC_TOKEN": os.environ["SPLUNK_HEC_TOKEN"],
    "PROXY_API_KEY": os.environ["PROXY_API_KEY"],
}
if os.environ.get("HF_TOKEN"):
    out["HF_TOKEN"] = os.environ["HF_TOKEN"]
print(json.dumps(out))
PY
)"
if aws secretsmanager describe-secret --region "${REGION}" --secret-id "${SECRET_ID}" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --region "${REGION}" --secret-id "${SECRET_ID}" \
    --secret-string "${SECRET_JSON}" >/dev/null
else
  aws secretsmanager create-secret --region "${REGION}" --name "${SECRET_ID}" \
    --secret-string "${SECRET_JSON}" >/dev/null
fi

# ---------------------------------------------------------------------------
# 5. Resolve the S3 managed prefix list (for airgapped SG egress)
# ---------------------------------------------------------------------------
S3_PREFIX_LIST_ID="$(aws ec2 describe-managed-prefix-lists --region "${REGION}" \
  --filters "Name=prefix-list-name,Values=com.amazonaws.${REGION}.s3" \
  --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null || true)"
[[ "${S3_PREFIX_LIST_ID}" == "None" ]] && S3_PREFIX_LIST_ID=""
echo "S3 prefix list: ${S3_PREFIX_LIST_ID:-<none>}"

# ---------------------------------------------------------------------------
# 6. Package + deploy the per-environment stack
# ---------------------------------------------------------------------------
MAIN_STACK="${RESOURCE_NAME_PREFIX}-${ENVIRONMENT}"
TS="$(date '+%Y%m%d-%H%M%S')"
ARTIFACT_PREFIX="cfn/${MAIN_STACK}-${TS}"
PACKAGED="/tmp/${MAIN_STACK}-packaged.yaml"
SCRIPTS_ARCHIVE="/tmp/${MAIN_STACK}-scripts.tar.gz"
SCRIPTS_S3_KEY="${ARTIFACT_PREFIX}/splunk-ai-scripts.tar.gz"

echo "== Packaging main stack to s3://${APPS_LICENSE_BUCKET}/${ARTIFACT_PREFIX} =="
aws cloudformation package --region "${REGION}" \
  --template-file "${CFN_DIR}/main.yaml" \
  --s3-bucket "${APPS_LICENSE_BUCKET}" --s3-prefix "${ARTIFACT_PREFIX}" \
  --output-template-file "${PACKAGED}"

echo "== Uploading bootstrap scripts (+ token-meter proxy files) =="
tar -C "${PLATFORM_DIR}" -czf "${SCRIPTS_ARCHIVE}" scripts token-meter-proxy
# Verify contents without piping tar into grep -q (grep's early exit can SIGPIPE tar
# under `set -o pipefail`); read the listing once, then match via here-strings.
_arch_list="$(tar -tzf "${SCRIPTS_ARCHIVE}")"
for _need in scripts/bootstrap-gpu.sh scripts/bootstrap-searchhead.sh token-meter-proxy/app.py; do
  grep -qx "${_need}" <<<"${_arch_list}" || { echo "ERROR: bootstrap archive missing ${_need}" >&2; exit 1; }
done
aws s3 cp "${SCRIPTS_ARCHIVE}" "s3://${APPS_LICENSE_BUCKET}/${SCRIPTS_S3_KEY}" --region "${REGION}"
BOOTSTRAP_SCRIPTS_URL="$(aws s3 presign "s3://${APPS_LICENSE_BUCKET}/${SCRIPTS_S3_KEY}" --region "${REGION}" --expires-in 604800)"

# Pass-through params from the config JSON, minus the ones deploy.sh computes.
COMPUTED_KEYS='["ContainerImageProfilesJson","SplunkMltkGpuImage","SplunkLlmRagImage","DsdlCpuInferenceImage","OllamaImage","EtcdImage","MinioImage","MilvusImage","NvidiaTestImage","VllmImage","TokenMeterProxyImage"]'
# (portable; avoids `mapfile`, which macOS's bash 3.2 lacks)
BASE_OVERRIDES=()
while IFS= read -r _ov; do
  [[ -n "${_ov}" ]] && BASE_OVERRIDES+=("${_ov}")
done < <(jq -r --argjson skip "${COMPUTED_KEYS}" \
  '.[] | select(.ParameterKey as $k | ($skip | index($k)) | not) | "\(.ParameterKey)=\(.ParameterValue)"' "${PARAM_FILE}")

echo "== Deploying ${MAIN_STACK} =="
aws cloudformation deploy --region "${REGION}" --stack-name "${MAIN_STACK}" \
  --template-file "${PACKAGED}" --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "${BASE_OVERRIDES[@]}" \
    VpcId="${VPC_ID}" \
    PublicSubnetId="${PUBLIC_SUBNET_ID}" \
    VpcCidr="${VPC_CIDR}" \
    AiArtifactsBucket="${AI_ARTIFACTS_BUCKET}" \
    AppsLicenseBucket="${APPS_LICENSE_BUCKET}" \
    EcrRegistryUri="${ECR_REGISTRY_URI}" \
    EcrRepositoryName="${ECR_REPOSITORY_NAME}" \
    InstanceProfileName="${INSTANCE_PROFILE_NAME}" \
    S3PrefixListId="${S3_PREFIX_LIST_ID}" \
    AllowedSshCidr="${ALLOWED_SSH_CIDR}" \
    AllowedSplunkUiCidr="${ALLOWED_SPLUNK_UI_CIDR}" \
    AmiId="${AMI_ID}" \
    SearchHeadAmiId="${SEARCH_HEAD_AMI_ID}" \
    SecretsManagerSecretId="${SECRET_ID}" \
    BootstrapScriptsS3Key="${SCRIPTS_S3_KEY}" \
    BootstrapScriptsUrl="${BOOTSTRAP_SCRIPTS_URL}" \
    ContainerImageProfilesJson="${CONTAINER_IMAGE_PROFILES_JSON}" \
    SplunkMltkGpuImage="${MLTK_GPU_IMAGE}" \
    SplunkLlmRagImage="${LLM_RAG_IMAGE}" \
    DsdlCpuInferenceImage="${CPU_IMAGE}" \
    OllamaImage="${OLLAMA_IMAGE}" \
    EtcdImage="${ETCD_IMAGE}" \
    MinioImage="${MINIO_IMAGE}" \
    MilvusImage="${MILVUS_IMAGE}" \
    NvidiaTestImage="${CUDA_IMAGE}" \
    VllmImage="${VLLM_IMAGE}" \
    TokenMeterProxyImage="${PROXY_IMAGE}"

echo "== Deployment complete: ${MAIN_STACK} =="
aws cloudformation describe-stacks --region "${REGION}" --stack-name "${MAIN_STACK}" \
  --query 'Stacks[0].Outputs' --output table
