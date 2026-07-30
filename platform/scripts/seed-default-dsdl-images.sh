#!/usr/bin/env bash
set -euo pipefail

# Seed the DEFAULT Splunk DSDL container images into ECR for the airgapped
# environment. Runs on an internet-connected operator machine with Docker:
# pulls each default image from Docker Hub, retags it into the shared ECR
# repository (single repo, one tag per image), and pushes it.
#
# The airgapped instances then pull these images from ECR (never Docker Hub),
# and generate_default_images_conf.py points DSDL's local/images.conf at them.
#
#   ./seed-default-dsdl-images.sh <aws-region>
#
# Required env (deploy.sh provides these from the storage stack outputs):
#   ECR_REGISTRY_URI     e.g. 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com
#   ECR_REPOSITORY_NAME  e.g. splunk-ai-containers-ab12c
# Optional env:
#   DSDL_IMAGES_MANIFEST  path to dsdl-default-images.json (default: alongside this script)
#   SKIP_ARM=true         skip the arm64 golden image (it cannot run on x86 instances)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGION="${1:-${AWS_REGION:-}}"
ECR_REGISTRY_URI="${ECR_REGISTRY_URI:-}"
ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-}"
MANIFEST="${DSDL_IMAGES_MANIFEST:-${SCRIPT_DIR}/dsdl-default-images.json}"
SKIP_ARM="${SKIP_ARM:-false}"

for tool in aws jq docker; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required" >&2; exit 1; }
done
[[ -n "${REGION}" ]] || { echo "ERROR: region required (arg 1 or AWS_REGION)" >&2; exit 1; }
[[ -n "${ECR_REGISTRY_URI}" && -n "${ECR_REPOSITORY_NAME}" ]] || {
  echo "ERROR: ECR_REGISTRY_URI and ECR_REPOSITORY_NAME must be set" >&2; exit 1; }
[[ -f "${MANIFEST}" ]] || { echo "ERROR: manifest not found: ${MANIFEST}" >&2; exit 1; }

REPO_URI="${ECR_REGISTRY_URI}/${ECR_REPOSITORY_NAME}"

echo "Logging in to ECR registry ${ECR_REGISTRY_URI}"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY_URI}" >/dev/null

count=0
failed=0
while IFS=$'\t' read -r stanza source ecr_tag; do
  if [[ "${SKIP_ARM}" == "true" && "${stanza}" == "golden-cpu-arm" ]]; then
    echo "Skipping ${stanza} (SKIP_ARM=true)"
    continue
  fi
  target="${REPO_URI}:${ecr_tag}"
  echo "==> ${source}  ->  ${target}"
  if ! docker pull --platform "${DOCKER_PLATFORM:-linux/amd64}" "${source}"; then
    echo "WARN: failed to pull ${source}; skipping" >&2; failed=$((failed+1)); continue
  fi
  docker tag "${source}" "${target}"
  if ! docker push "${target}"; then
    echo "WARN: failed to push ${target}" >&2; failed=$((failed+1)); continue
  fi
  count=$((count+1))
done < <(jq -r '.images[] | [.stanza, .source, .ecr_tag] | @tsv' "${MANIFEST}")

echo "Seeded ${count} default DSDL image(s) into ${REPO_URI} (${failed} failed)."
[[ "${failed}" -eq 0 ]]
