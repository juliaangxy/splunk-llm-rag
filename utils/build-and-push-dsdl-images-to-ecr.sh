#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./utils/build-and-push-dsdl-images-to-ecr.sh <region> <target-ecr-repository-uri> [image-version] [repo-ref]

Description:
  Clones splunk/splunk-mltk-container-docker, builds required images,
  and pushes them to the provided ECR repository URI.

Required positional args:
  region                       AWS region, e.g. ap-southeast-1
  target-ecr-repository-uri    Full URI, e.g.
                               123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/my-shared-repo

Optional positional args:
  image-version                Image version/tag passed to build.sh (default: 5.2.3)
  repo-ref                     Git branch/tag/commit to checkout (default: master)

Optional environment variables:
  BUILD_GOLDEN_CPU             true|false (default: true)
  BUILD_REPO_URL               (default: https://github.com/splunk/splunk-mltk-container-docker.git)
  BUILD_WORKDIR                Existing dir to reuse. If unset, mktemp dir is used and auto-cleaned.

Notes:
  - Builds the tags: golden-gpu and ubi-llm-rag.
  - Builds golden-cpu by default to provide a DSDL CPU fallback image.
  - Pushes tags compatible with this project:
      mltk-container-golden-gpu-<version>
      mltk-container-ubi-llm-rag-<version>
      mltk-container-golden-cpu-<version> (when BUILD_GOLDEN_CPU=true)
EOF
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

REGION="$1"
TARGET_REPO_URI="$2"
IMAGE_VERSION="${3:-5.2.3}"
BUILD_REPO_REF="${4:-master}"

BUILD_GOLDEN_CPU="${BUILD_GOLDEN_CPU:-true}"
BUILD_REPO_URL="${BUILD_REPO_URL:-https://github.com/splunk/splunk-mltk-container-docker.git}"

if [[ "${TARGET_REPO_URI}" != *"/"* ]]; then
  echo "ERROR: target-ecr-repository-uri must include registry and repository path" >&2
  exit 1
fi

ECR_REGISTRY_URI="${TARGET_REPO_URI%%/*}"
TARGET_REPO_NAME="${TARGET_REPO_URI#*/}"

for cmd in git docker aws bash; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: ${cmd}" >&2
    exit 1
  fi
done

if [[ -n "${BUILD_WORKDIR:-}" ]]; then
  WORKDIR="${BUILD_WORKDIR}"
  mkdir -p "${WORKDIR}"
  CLEANUP_WORKDIR=false
else
  WORKDIR="$(mktemp -d -t dsdl-image-build.XXXXXX)"
  CLEANUP_WORKDIR=true
fi

cleanup() {
  if [[ "${CLEANUP_WORKDIR}" == "true" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

BUILD_SRC_DIR="${WORKDIR}/splunk-mltk-container-docker"

echo "Cloning ${BUILD_REPO_URL} into ${BUILD_SRC_DIR}"
git clone "${BUILD_REPO_URL}" "${BUILD_SRC_DIR}"

pushd "${BUILD_SRC_DIR}" >/dev/null

echo "Checking out ${BUILD_REPO_REF}"
git checkout "${BUILD_REPO_REF}"

LOCAL_REPO_PREFIX="localbuild/"

echo "Building golden-gpu:${IMAGE_VERSION}"
./build.sh golden-gpu "${LOCAL_REPO_PREFIX}" "${IMAGE_VERSION}"

echo "Building ubi-llm-rag:${IMAGE_VERSION}"
./build.sh ubi-llm-rag "${LOCAL_REPO_PREFIX}" "${IMAGE_VERSION}"

if [[ "${BUILD_GOLDEN_CPU}" == "true" ]]; then
  echo "Building golden-cpu:${IMAGE_VERSION}"
  ./build.sh golden-cpu "${LOCAL_REPO_PREFIX}" "${IMAGE_VERSION}"
fi

popd >/dev/null

declare -a mappings=(
  "${LOCAL_REPO_PREFIX}mltk-container-golden-gpu:${IMAGE_VERSION}=${TARGET_REPO_NAME}"
  "${LOCAL_REPO_PREFIX}mltk-container-ubi-llm-rag:${IMAGE_VERSION}=${TARGET_REPO_NAME}"
)

if [[ "${BUILD_GOLDEN_CPU}" == "true" ]]; then
  mappings+=("${LOCAL_REPO_PREFIX}mltk-container-golden-cpu:${IMAGE_VERSION}=${TARGET_REPO_NAME}")
fi

echo "Pushing built images to ${TARGET_REPO_URI}"
ECR_REGISTRY_URI="${ECR_REGISTRY_URI}" ECR_REPOSITORY_NAME="" \
  "${REPO_ROOT}/utils/push-docker-images-to-ecr.sh" "${REGION}" "${mappings[@]}"

echo
echo "Use these image URIs in bootstrap/main stack:"
echo "SPLUNK_MLTK_GPU_IMAGE=${TARGET_REPO_URI}:mltk-container-golden-gpu-${IMAGE_VERSION}"
echo "SPLUNK_LLM_RAG_IMAGE=${TARGET_REPO_URI}:mltk-container-ubi-llm-rag-${IMAGE_VERSION}"
if [[ "${BUILD_GOLDEN_CPU}" == "true" ]]; then
  echo "DSDL_CPU_INFERENCE_IMAGE=${TARGET_REPO_URI}:mltk-container-golden-cpu-${IMAGE_VERSION}"
fi
